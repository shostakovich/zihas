require "test_helper"
require "aggregator"
require "tzinfo"
require "fileutils"
require "tmpdir"

class AggregatorTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    Sample.delete_all
    Sample5min.delete_all
    DailyTotal.delete_all
    DailyEnergySummary.delete_all  # <-- add this line

    @tz         = TZInfo::Timezone.get("Europe/Berlin")
    @aggregator = Aggregator.new(timezone: @tz, raw_retention_days: 7)
  end

  # Local Europe/Berlin date "2026-04-10" = 2026-04-10 00:00 Berlin = 22:00 UTC previous day
  def berlin_midnight_utc(date_s)
    @tz.local_to_utc(Time.parse("#{date_s} 00:00:00")).to_i
  end

  def seed_day(plug_id:, date:, start_energy:, end_energy:, start_power: 0, end_power: 0)
    start_ts = berlin_midnight_utc(date)
    (0..23).each do |h|
      ratio = h / 23.0
      Sample.create!(
        plug_id:    plug_id,
        ts:         start_ts + h * 3600,
        apower_w:   start_power  + (end_power  - start_power)  * ratio,
        aenergy_wh: start_energy + (end_energy - start_energy) * ratio
      )
    end
  end

  test "daily total is energy delta" do
    seed_day(plug_id: "bkw", date: "2026-04-10", start_energy: 1000.0, end_energy: 1800.0)
    @aggregator.aggregate_day("2026-04-10")
    row = DailyTotal.find_by!(plug_id: "bkw", date: "2026-04-10")
    assert_in_delta 800.0, row.energy_wh
  end

  test "aggregate_day writes 5-minute samples" do
    start_ts = berlin_midnight_utc("2026-04-10")
    Sample.create!(plug_id: "bkw", ts: start_ts + 0, apower_w: 10, aenergy_wh: 100)
    Sample.create!(plug_id: "bkw", ts: start_ts + 60, apower_w: 20, aenergy_wh: 103)
    Sample.create!(plug_id: "bkw", ts: start_ts + 300, apower_w: 40, aenergy_wh: 110)

    @aggregator.aggregate_day("2026-04-10")

    rows = ActiveRecord::Base.connection.exec_query(
      "SELECT plug_id, bucket_ts, avg_power_w, energy_delta_wh, sample_count FROM samples_5min ORDER BY bucket_ts"
    ).to_a

    assert_equal 2, rows.length
    assert_equal({
      "plug_id" => "bkw",
      "bucket_ts" => start_ts,
      "avg_power_w" => 15.0,
      "energy_delta_wh" => 3.0,
      "sample_count" => 2
    }, rows.first)
    assert_equal({
      "plug_id" => "bkw",
      "bucket_ts" => start_ts + 300,
      "avg_power_w" => 40.0,
      "energy_delta_wh" => 7.0,
      "sample_count" => 1
    }, rows.second)
  end

  test "daily total handles meter reset" do
    start_ts = berlin_midnight_utc("2026-04-10")

    Sample.create!(plug_id: "bkw", ts: start_ts,        apower_w: 0, aenergy_wh: 424_440.0)
    Sample.create!(plug_id: "bkw", ts: start_ts + 3600, apower_w: 0, aenergy_wh: 424_440.0)
    Sample.create!(plug_id: "bkw", ts: start_ts + 7200, apower_w: 0, aenergy_wh: 0.0)
    Sample.create!(plug_id: "bkw", ts: start_ts + 7260, apower_w: 0, aenergy_wh: 100.0)

    @aggregator.aggregate_day("2026-04-10")

    row = DailyTotal.find_by!(plug_id: "bkw", date: "2026-04-10")
    assert_in_delta 100.0, row.energy_wh
  end

  test "daily total ignores glitch zero then jump back" do
    start_ts = berlin_midnight_utc("2026-04-10")

    Sample.create!(plug_id: "bkw", ts: start_ts,      apower_w: 145, aenergy_wh: 425_000.0)
    Sample.create!(plug_id: "bkw", ts: start_ts + 5,  apower_w: 145, aenergy_wh: 0.0)
    Sample.create!(plug_id: "bkw", ts: start_ts + 10, apower_w: 145, aenergy_wh: 425_005.0)
    Sample.create!(plug_id: "bkw", ts: start_ts + 15, apower_w: 145, aenergy_wh: 425_010.0)

    @aggregator.aggregate_day("2026-04-10")

    row = DailyTotal.find_by!(plug_id: "bkw", date: "2026-04-10")
    assert_in_delta 5.0, row.energy_wh
  end

  test "aggregate_day is idempotent" do
    seed_day(plug_id: "bkw", date: "2026-04-10",
             start_power: 50, end_power: 50, start_energy: 0, end_energy: 1200)
    @aggregator.aggregate_day("2026-04-10")
    first_count_5min = Sample5min.count
    first_total = DailyTotal.first.energy_wh
    @aggregator.aggregate_day("2026-04-10")
    assert_equal first_count_5min, Sample5min.count
    assert_in_delta first_total, DailyTotal.first.energy_wh
    assert_equal 1, DailyTotal.count
  end

  test "purge deletes samples older than retention" do
    old_ts   = Time.now.to_i - 10 * 86_400
    fresh_ts = Time.now.to_i - 1 * 86_400
    Sample.create!(plug_id: "bkw", ts: old_ts,   apower_w: 1, aenergy_wh: 1)
    Sample.create!(plug_id: "bkw", ts: fresh_ts, apower_w: 2, aenergy_wh: 2)
    @aggregator.purge_old_raw!
    assert_equal [ fresh_ts ], Sample.pluck(:ts)
  end

  test "aggregate_day with no samples does not raise" do
    @aggregator.aggregate_day("1999-01-01")
    assert_equal 0, DailyTotal.count
  end

  test "backup creates sqlite file" do
    Dir.mktmpdir do |tmp|
      Sample.create!(plug_id: "bkw", ts: 1, apower_w: 0, aenergy_wh: 0)
      backup_dir = File.join(tmp, "backup")
      @aggregator.backup!(backup_dir)

      files = Dir.glob("#{backup_dir}/*.db")
      assert_equal 1, files.length
      assert_match(/ziwoas-\d{4}-\d{2}-\d{2}\.db\z/, files.first)
      assert File.size(files.first) > 0
    end
  end

  test "backup keeps only 7 most recent" do
    Dir.mktmpdir do |tmp|
      backup_dir = File.join(tmp, "backup")
      FileUtils.mkdir_p(backup_dir)

      10.times do |i|
        path = File.join(backup_dir, "ziwoas-2026-04-#{format('%02d', i + 1)}.db")
        File.write(path, "fake#{i}")
        File.utime(Time.now - (10 - i) * 86_400, Time.now - (10 - i) * 86_400, path)
      end

      @aggregator.backup!(backup_dir)

      remaining = Dir.glob("#{backup_dir}/*.db").map { |f| File.basename(f) }.sort
      assert_equal 7, remaining.length
      assert remaining.any? { |f| f.include?(Date.today.to_s) }
    end
  end

  test "run_once with no samples returns without error" do
    assert_nothing_raised { @aggregator.run_once }
    assert_equal 0, DailyTotal.count
  end

  test "run_once skips days already in daily_totals" do
    seed_day(plug_id: "bkw", date: "2026-04-10", start_energy: 0, end_energy: 800)
    @aggregator.aggregate_day("2026-04-10")
    count_before = DailyTotal.count

    @aggregator.run_once(today: Date.new(2026, 4, 11))
    assert_equal count_before, DailyTotal.count
  end

  test "run_once aggregates missing days up to yesterday" do
    seed_day(plug_id: "bkw", date: "2026-04-10", start_energy: 0, end_energy: 800)
    seed_day(plug_id: "bkw", date: "2026-04-11", start_energy: 800, end_energy: 1600)

    @aggregator.run_once(today: Date.new(2026, 4, 12))
    assert_equal 2, DailyTotal.count
    assert DailyTotal.find_by(plug_id: "bkw", date: "2026-04-10")
    assert DailyTotal.find_by(plug_id: "bkw", date: "2026-04-11")
  end

  test "purge_old_raw! preserves records within retention window" do
    now = Time.now.to_i
    Sample.create!(plug_id: "bkw", ts: now - 3 * 86_400, apower_w: 1, aenergy_wh: 1)
    @aggregator.purge_old_raw!
    assert_equal 1, Sample.count
  end

  test "aggregate_day writes daily_energy_summary row" do
    plugs = [
      ConfigLoader::PlugCfg.new(id: "bkw",    name: "BKW",    role: :producer, driver: :shelly, ain: nil),
      ConfigLoader::PlugCfg.new(id: "fridge", name: "Fridge", role: :consumer, driver: :shelly, ain: nil)
    ]
    aggregator = Aggregator.new(timezone: @tz, raw_retention_days: 7, plugs: plugs)

    start_ts = berlin_midnight_utc("2026-04-10")
    # 1 hour of producer 200W and consumer 100W simultaneously, sampled every minute
    (0..3600).step(60) do |dt|
      Sample.create!(plug_id: "bkw",    ts: start_ts + dt, apower_w: 200.0, aenergy_wh: 200.0 * dt / 3600.0)
      Sample.create!(plug_id: "fridge", ts: start_ts + dt, apower_w: 100.0, aenergy_wh: 100.0 * dt / 3600.0)
    end

    aggregator.aggregate_day("2026-04-10")

    summary = DailyEnergySummary.find("2026-04-10")
    assert_in_delta 200.0, summary.produced_wh,      1.0
    assert_in_delta 100.0, summary.consumed_wh,      1.0
    assert_in_delta 100.0, summary.self_consumed_wh, 1.0
  end

  test "aggregate_day is idempotent for daily_energy_summary" do
    plugs = [
      ConfigLoader::PlugCfg.new(id: "bkw",    name: "BKW",    role: :producer, driver: :shelly, ain: nil),
      ConfigLoader::PlugCfg.new(id: "fridge", name: "Fridge", role: :consumer, driver: :shelly, ain: nil)
    ]
    aggregator = Aggregator.new(timezone: @tz, raw_retention_days: 7, plugs: plugs)

    start_ts = berlin_midnight_utc("2026-04-10")
    Sample.create!(plug_id: "bkw",    ts: start_ts,         apower_w: 200, aenergy_wh: 0)
    Sample.create!(plug_id: "bkw",    ts: start_ts + 600,   apower_w: 200, aenergy_wh: 33.3)
    Sample.create!(plug_id: "fridge", ts: start_ts,         apower_w: 100, aenergy_wh: 0)
    Sample.create!(plug_id: "fridge", ts: start_ts + 600,   apower_w: 100, aenergy_wh: 16.7)

    aggregator.aggregate_day("2026-04-10")
    first = DailyEnergySummary.find("2026-04-10").attributes
    aggregator.aggregate_day("2026-04-10")

    assert_equal 1, DailyEnergySummary.count
    assert_in_delta first.fetch("self_consumed_wh"), DailyEnergySummary.find("2026-04-10").self_consumed_wh, 0.01
  end

  test "aggregate_day does not write summary when plugs are not provided" do
    aggregator = Aggregator.new(timezone: @tz, raw_retention_days: 7)
    seed_day(plug_id: "bkw", date: "2026-04-10", start_energy: 1000.0, end_energy: 1800.0)

    aggregator.aggregate_day("2026-04-10")
    assert_equal 0, DailyEnergySummary.count
  end
end

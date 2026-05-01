require "test_helper"
require "aggregator"
require "tzinfo"
require "fileutils"
require "tmpdir"

class AggregatorTest < ActiveSupport::TestCase
  setup do
    Sample.delete_all
    Sample5min.delete_all
    DailyTotal.delete_all

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

  test "5-min buckets are populated" do
    seed_day(plug_id: "bkw", date: "2026-04-10",
             start_power: 100, end_power: 100, start_energy: 0, end_energy: 2400)
    @aggregator.aggregate_day("2026-04-10")
    count = Sample5min.where(plug_id: "bkw").count
    assert_operator count, :>, 20
  end

  test "aggregate_day is idempotent" do
    seed_day(plug_id: "bkw", date: "2026-04-10",
             start_power: 50, end_power: 50, start_energy: 0, end_energy: 1200)
    @aggregator.aggregate_day("2026-04-10")
    first_count_5min = Sample5min.count
    first_total      = DailyTotal.first.energy_wh
    @aggregator.aggregate_day("2026-04-10")
    assert_equal first_count_5min, Sample5min.count
    assert_in_delta first_total, DailyTotal.first.energy_wh
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
end

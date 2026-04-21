require "test_helper"
require "aggregator"
require "db"
require "tzinfo"
require "fileutils"
require "tmpdir"

class AggregatorTest < Minitest::Test
  def setup
    @db = DB.connect(":memory:")
    DB.migrate!(@db)
    @tz = TZInfo::Timezone.get("Europe/Berlin")
    @aggregator = Aggregator.new(db: @db, timezone: @tz, raw_retention_days: 7)
  end

  # Local Europe/Berlin date "2026-04-10" = 2026-04-10 00:00 Berlin = 22:00 UTC previous day
  def berlin_midnight_utc(date_s)
    @tz.local_to_utc(Time.parse("#{date_s} 00:00:00")).to_i
  end

  def seed_day(plug_id:, date:, start_power:, end_power:, start_energy:, end_energy:)
    start_ts = berlin_midnight_utc(date)
    end_ts   = berlin_midnight_utc(date) + 86_400 - 1
    # 24 samples, one per hour
    (0..23).each do |h|
      ratio = h / 23.0
      @db[:samples].insert(
        plug_id: plug_id,
        ts:      start_ts + h * 3600,
        apower_w:   start_power  + (end_power  - start_power)  * ratio,
        aenergy_wh: start_energy + (end_energy - start_energy) * ratio,
      )
    end
  end

  def test_daily_total_is_energy_delta
    seed_day(plug_id: "bkw", date: "2026-04-10",
             start_power: 0, end_power: 0, start_energy: 1000.0, end_energy: 1800.0)
    @aggregator.aggregate_day("2026-04-10")
    row = @db[:daily_totals].first(plug_id: "bkw", date: "2026-04-10")
    assert_in_delta 800.0, row[:energy_wh]
  end

  def test_5min_buckets_are_populated
    seed_day(plug_id: "bkw", date: "2026-04-10",
             start_power: 100, end_power: 100, start_energy: 0, end_energy: 2400)
    @aggregator.aggregate_day("2026-04-10")
    count = @db[:samples_5min].where(plug_id: "bkw").count
    assert_operator count, :>, 20
  end

  def test_aggregate_day_is_idempotent
    seed_day(plug_id: "bkw", date: "2026-04-10",
             start_power: 50, end_power: 50, start_energy: 0, end_energy: 1200)
    @aggregator.aggregate_day("2026-04-10")
    first_count_5min = @db[:samples_5min].count
    first_total      = @db[:daily_totals].first[:energy_wh]
    @aggregator.aggregate_day("2026-04-10")
    assert_equal first_count_5min, @db[:samples_5min].count
    assert_in_delta first_total, @db[:daily_totals].first[:energy_wh]
  end

  def test_purge_deletes_samples_older_than_retention
    old_ts   = Time.now.to_i - 10 * 86_400
    fresh_ts = Time.now.to_i - 1 * 86_400
    @db[:samples].insert(plug_id: "bkw", ts: old_ts,   apower_w: 1, aenergy_wh: 1)
    @db[:samples].insert(plug_id: "bkw", ts: fresh_ts, apower_w: 2, aenergy_wh: 2)
    @aggregator.purge_old_raw!
    remaining_ts = @db[:samples].map(:ts)
    assert_equal [fresh_ts], remaining_ts
  end

  def test_ignores_days_with_no_samples
    @aggregator.aggregate_day("1999-01-01") # must not raise
    assert_equal 0, @db[:daily_totals].count
  end

  def test_backup_creates_sqlite_file
    Dir.mktmpdir do |tmp|
      # switch DB to a file so .backup has something real
      file_db = File.join(tmp, "live.db")
      db = DB.connect(file_db)
      DB.migrate!(db)
      db[:samples].insert(plug_id: "bkw", ts: 1, apower_w: 0, aenergy_wh: 0)

      agg = Aggregator.new(db: db, timezone: @tz, raw_retention_days: 7)
      backup_dir = File.join(tmp, "backup")
      agg.backup!(backup_dir)

      files = Dir.glob("#{backup_dir}/*.db")
      assert_equal 1, files.length
      assert_match(/ziwoas-\d{4}-\d{2}-\d{2}\.db\z/, files.first)
      assert File.size(files.first) > 0

      # Backup file is itself a valid SQLite DB
      restored = DB.connect(files.first)
      assert_equal 1, restored[:samples].count
    end
  end

  def test_backup_keeps_only_7_most_recent
    Dir.mktmpdir do |tmp|
      file_db = File.join(tmp, "live.db")
      db = DB.connect(file_db)
      DB.migrate!(db)
      backup_dir = File.join(tmp, "backup")
      FileUtils.mkdir_p(backup_dir)

      # Pre-seed 10 fake snapshots with staggered mtimes
      10.times do |i|
        path = File.join(backup_dir, "ziwoas-2026-04-#{format('%02d', i + 1)}.db")
        File.write(path, "fake#{i}")
        File.utime(Time.now - (10 - i) * 86_400, Time.now - (10 - i) * 86_400, path)
      end

      agg = Aggregator.new(db: db, timezone: @tz, raw_retention_days: 7)
      agg.backup!(backup_dir)

      remaining = Dir.glob("#{backup_dir}/*.db").map { |f| File.basename(f) }.sort
      assert_equal 7, remaining.length
      # 6 pre-seeded + 1 fresh snapshot from this run
      assert(remaining.any? { |f| f.include?(Date.today.to_s) })
    end
  end
end

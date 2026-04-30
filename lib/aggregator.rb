require "date"
require "fileutils"
require "set"
require "time"

class Aggregator
  def initialize(db:, timezone:, raw_retention_days:)
    @db = db
    @tz = timezone
    @raw_retention_days = raw_retention_days
  end

  def aggregate_day(date_s)
    start_ts = @tz.local_to_utc(Time.parse("#{date_s} 00:00:00")).to_i
    end_ts   = start_ts + 86_400

    @db.transaction do
      @db[:samples_5min]
        .where(bucket_ts: start_ts..(end_ts - 1))
        .delete
      @db[:daily_totals].where(date: date_s).delete

      sql_5min = <<~SQL
        WITH window_samples AS (
          SELECT plug_id, ts, apower_w, aenergy_wh,
                 LAG(aenergy_wh) OVER (PARTITION BY plug_id ORDER BY ts) AS prev_wh
            FROM samples
           WHERE ts >= ? AND ts < ?
        ),
        deltas AS (
          SELECT plug_id, ts, apower_w,
                 CASE
                   WHEN prev_wh IS NULL       THEN 0
                   WHEN aenergy_wh >= prev_wh THEN aenergy_wh - prev_wh
                   ELSE aenergy_wh
                 END AS delta_wh
            FROM window_samples
        )
        INSERT INTO samples_5min (plug_id, bucket_ts, avg_power_w, energy_delta_wh, sample_count)
        SELECT plug_id,
               (ts / 300) * 300   AS bucket_ts,
               AVG(apower_w)      AS avg_power_w,
               SUM(delta_wh)      AS energy_delta_wh,
               COUNT(*)           AS sample_count
          FROM deltas
         GROUP BY plug_id, bucket_ts
      SQL

      sql_daily = <<~SQL
        WITH window_samples AS (
          SELECT plug_id, ts, aenergy_wh,
                 LAG(aenergy_wh) OVER (PARTITION BY plug_id ORDER BY ts) AS prev_wh
            FROM samples
           WHERE ts >= ? AND ts < ?
        ),
        deltas AS (
          SELECT plug_id,
                 CASE
                   WHEN prev_wh IS NULL       THEN 0
                   WHEN aenergy_wh >= prev_wh THEN aenergy_wh - prev_wh
                   ELSE aenergy_wh
                 END AS delta_wh
            FROM window_samples
        )
        INSERT INTO daily_totals (plug_id, date, energy_wh)
        SELECT plug_id, ?, SUM(delta_wh) AS energy_wh
          FROM deltas
         GROUP BY plug_id
      SQL

      @db.synchronize do |conn|
        conn.execute(sql_5min, [start_ts, end_ts])
        conn.execute(sql_daily, [start_ts, end_ts, date_s])
      end
    end
  end

  def purge_old_raw!
    cutoff = Time.now.to_i - @raw_retention_days * 86_400
    @db[:samples].where { ts < cutoff }.delete
  end

  def backup!(backup_dir, today: Date.today, keep: 7)
    FileUtils.mkdir_p(backup_dir)
    filename = File.join(backup_dir, "ziwoas-#{today}.db")
    File.delete(filename) if File.exist?(filename)

    @db.synchronize { |c| c.execute("VACUUM INTO ?", [filename]) }

    prune_old_backups(backup_dir, keep)
  end

  # Aggregate any finished day not yet in daily_totals, then purge.
  def run_once(today: Date.today)
    existing = @db[:daily_totals].select_map(:date).uniq.to_set
    earliest = earliest_sample_date
    return if earliest.nil?

    (earliest..(today - 1)).each do |d|
      date_s = d.to_s
      next if existing.include?(date_s)
      aggregate_day(date_s)
    end

    purge_old_raw!
  end

  private

  def earliest_sample_date
    min_ts = @db[:samples].min(:ts)
    return nil if min_ts.nil?
    Time.at(min_ts).utc.to_date
  end

  def prune_old_backups(dir, keep)
    files = Dir.glob("#{dir}/ziwoas-*.db").sort_by { |f| File.mtime(f) }
    (files.length - keep).times { File.delete(files.shift) } if files.length > keep
  end
end

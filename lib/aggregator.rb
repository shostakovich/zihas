require "date"
require "fileutils"
require "set"
require "time"

class Aggregator
  def initialize(timezone:, raw_retention_days:)
    @tz = timezone
    @raw_retention_days = raw_retention_days
  end

  def aggregate_day(date_s)
    start_ts = @tz.local_to_utc(Time.parse("#{date_s} 00:00:00")).to_i
    end_ts   = start_ts + 86_400

    ActiveRecord::Base.transaction do
      DailyTotal.where(date: date_s).delete_all

      sql_daily = <<~SQL
        INSERT INTO daily_totals (plug_id, date, energy_wh)
        SELECT plug_id, ?,
               MAX(aenergy_wh) - MIN(aenergy_wh) AS energy_wh
          FROM samples
         WHERE ts >= ? AND ts < ?
         GROUP BY plug_id
      SQL

      ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql_array([sql_daily, date_s, start_ts, end_ts])
      )
    end
  end

  def purge_old_raw!
    cutoff = Time.now.to_i - @raw_retention_days * 86_400
    Sample.where("ts < ?", cutoff).delete_all
  end

  def backup!(backup_dir, today: Date.today, keep: 7)
    FileUtils.mkdir_p(backup_dir)
    filename = File.join(backup_dir, "ziwoas-#{today}.db")
    File.delete(filename) if File.exist?(filename)

    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql_array(["VACUUM INTO ?", filename]))

    prune_old_backups(backup_dir, keep)
  end

  # Aggregate any finished day not yet in daily_totals, then purge.
  def run_once(today: Date.today)
    existing = DailyTotal.pluck(:date).to_set
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
    min_ts = Sample.minimum(:ts)
    return nil if min_ts.nil?
    Time.at(min_ts).utc.to_date
  end

  def prune_old_backups(dir, keep)
    files = Dir.glob("#{dir}/ziwoas-*.db").sort_by { |f| File.mtime(f) }
    (files.length - keep).times { File.delete(files.shift) } if files.length > keep
  end
end

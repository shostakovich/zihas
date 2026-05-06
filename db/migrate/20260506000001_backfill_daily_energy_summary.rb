require "config_loader"
require "daily_energy_summary_builder"
require "tzinfo"

class BackfillDailyEnergySummary < ActiveRecord::Migration[8.1]
  def up
    return if Rails.env.test?  # tests do their own seeding

    config_path = Rails.root.join("config", "ziwoas.yml")
    return unless File.exist?(config_path)

    config   = ConfigLoader.load(config_path.to_s)
    timezone = TZInfo::Timezone.get(config.timezone)
    builder  = DailyEnergySummaryBuilder.new(plugs: config.plugs, timezone: timezone)

    dates = DailyTotal.distinct.pluck(:date).sort
    dates.each do |date_s|
      next if DailyEnergySummary.exists?(date: date_s)

      day_start = timezone.local_to_utc(Time.parse("#{date_s} 00:00:00")).to_i
      day_end   = day_start + 86_400
      next unless Sample5min.where(bucket_ts: day_start...day_end).exists?

      result = builder.build(date_s)
      DailyEnergySummary.create!(
        date: date_s,
        produced_wh: result.fetch(:produced_wh),
        consumed_wh: result.fetch(:consumed_wh),
        self_consumed_wh: result.fetch(:self_consumed_wh)
      )
    end
  end

  def down
    DailyEnergySummary.delete_all
  end
end

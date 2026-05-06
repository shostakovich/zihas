require "config_loader"
require "daily_energy_summary_builder"
require "tzinfo"

namespace :daily_energy_summary do
  desc "Rebuild daily_energy_summary rows from samples_5min for every day in daily_totals"
  task rebuild: :environment do
    config_path = Rails.root.join("config", "ziwoas.yml")
    abort "config/ziwoas.yml missing" unless File.exist?(config_path)

    config   = ConfigLoader.load(config_path.to_s)
    timezone = TZInfo::Timezone.get(config.timezone)
    builder  = DailyEnergySummaryBuilder.new(plugs: config.plugs, timezone: timezone)

    dates = DailyTotal.distinct.pluck(:date).sort
    rebuilt = 0
    skipped = 0

    dates.each do |date_s|
      day_start = timezone.local_to_utc(Time.parse("#{date_s} 00:00:00")).to_i
      unless Sample5min.where(bucket_ts: day_start...(day_start + 86_400)).exists?
        skipped += 1
        next
      end

      result = builder.build(date_s)
      DailyEnergySummary.where(date: date_s).delete_all
      DailyEnergySummary.create!(
        date: date_s,
        produced_wh: result.fetch(:produced_wh),
        consumed_wh: result.fetch(:consumed_wh),
        self_consumed_wh: result.fetch(:self_consumed_wh)
      )
      rebuilt += 1
    end

    puts "Rebuilt #{rebuilt} days, skipped #{skipped} days without samples_5min."
  end
end

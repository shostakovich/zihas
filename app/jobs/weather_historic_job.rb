class WeatherHistoricJob < ApplicationJob
  queue_as :default

  def perform(today: Date.current)
    sync = WeatherSync.from_app_config
    return Rails.logger.info("weather: not configured") if sync.nil?
    sync.sync_historic_date(today - 1)
    sync.backfill_historic_from_daily_totals
  end
end

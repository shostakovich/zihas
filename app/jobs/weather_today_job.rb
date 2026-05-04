class WeatherTodayJob < ApplicationJob
  queue_as :default

  def perform(today: Date.current)
    sync = WeatherSync.from_app_config
    return Rails.logger.info("weather: not configured") if sync.nil?
    sync.sync_today(today: today)
  end
end

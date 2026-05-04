class WeatherCurrentJob < ApplicationJob
  queue_as :default

  def perform
    sync = WeatherSync.from_app_config
    return Rails.logger.info("weather: not configured") if sync.nil?
    sync.sync_current
  end
end

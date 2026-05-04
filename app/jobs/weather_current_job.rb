class WeatherCurrentJob < ApplicationJob
  queue_as :default

  def perform
    sync = WeatherSync.from_app_config
    return Rails.logger.info("weather: not configured") unless sync
    sync.sync_current
  end
end

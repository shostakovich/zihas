require "brightsky_client"

class WeatherTodayJob < ApplicationJob
  queue_as :default
  retry_on BrightskyClient::Error, wait: :polynomially_longer, attempts: 3

  def perform(today: Date.current)
    sync = WeatherSync.from_app_config
    return Rails.logger.info("weather: not configured") unless sync
    sync.sync_today(today: today)
    WeatherBroadcaster.broadcast_today
  end
end

module WeatherBroadcaster
  STREAM = "weather".freeze

  module_function

  def broadcast_current
    Turbo::StreamsChannel.broadcast_replace_to(
      STREAM,
      target: "weather_current",
      partial: "weather/current",
      locals: {
        current_weather:        WeatherRecord.latest_current,
        outdoor_sensor_reading: latest_fresh_outdoor_reading
      }
    )
    broadcast_empty_state
  end

  def broadcast_today
    Turbo::StreamsChannel.broadcast_replace_to(
      STREAM,
      target: "weather_today",
      partial: "weather/today",
      locals: { today_weather: WeatherRecord.today_hourly }
    )
    broadcast_empty_state
  end

  def broadcast_forecast
    Turbo::StreamsChannel.broadcast_replace_to(
      STREAM,
      target: "weather_forecast",
      partial: "weather/forecast",
      locals: { future_weather: WeatherRecord.future_days }
    )
    broadcast_empty_state
  end

  def broadcast_empty_state
    Turbo::StreamsChannel.broadcast_replace_to(
      STREAM,
      target: "weather_empty",
      partial: "weather/empty",
      locals: {
        current_weather: WeatherRecord.latest_current,
        today_weather: WeatherRecord.today_hourly,
        future_weather: WeatherRecord.future_days
      }
    )
  end

  def latest_fresh_outdoor_reading
    config = load_app_config
    return nil if config.nil?
    outdoor_ids = config.sensors.select { |s| s.type == :outdoor_meter }.map(&:id)
    SensorReading.fresh_outdoor(outdoor_ids)
  end

  def load_app_config
    require "config_loader"
    path = Rails.root.join("config", Rails.env.test? ? "ziwoas.test.yml" : "ziwoas.yml").to_s
    ConfigLoader.load(path)
  rescue Errno::ENOENT
    nil
  end
end

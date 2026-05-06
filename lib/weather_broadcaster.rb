module WeatherBroadcaster
  STREAM = "weather".freeze

  module_function

  def broadcast_current
    Turbo::StreamsChannel.broadcast_replace_to(
      STREAM,
      target: "weather_current",
      partial: "weather/current",
      locals: { current_weather: WeatherRecord.latest_current }
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
end

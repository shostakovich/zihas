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
  end

  def broadcast_today
    Turbo::StreamsChannel.broadcast_replace_to(
      STREAM,
      target: "weather_today",
      partial: "weather/today",
      locals: { today_weather: WeatherRecord.today_hourly }
    )
  end

  def broadcast_forecast
    Turbo::StreamsChannel.broadcast_replace_to(
      STREAM,
      target: "weather_forecast",
      partial: "weather/forecast",
      locals: { future_weather: WeatherRecord.future_days }
    )
  end
end

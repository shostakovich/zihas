class WeatherController < ApplicationController
  def index
    @current_weather        = WeatherRecord.latest_current
    @today_weather          = WeatherRecord.today_hourly
    @future_weather         = WeatherRecord.future_days
    @outdoor_sensor_reading = fresh_outdoor_sensor_reading
  end

  private

  def fresh_outdoor_sensor_reading
    SensorReading.fresh_outdoor(outdoor_sensor_ids)
  rescue ConfigLoader::Error
    nil
  end

  def outdoor_sensor_ids
    app_config.sensors.select { |s| s.type == :outdoor_meter }.map(&:id)
  end
end

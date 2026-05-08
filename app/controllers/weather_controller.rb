class WeatherController < ApplicationController
  SENSOR_FRESHNESS = 30.minutes

  def index
    @current_weather        = WeatherRecord.latest_current
    @today_weather          = WeatherRecord.today_hourly
    @future_weather         = WeatherRecord.future_days
    @outdoor_sensor_reading = fresh_outdoor_sensor_reading
  end

  private

  def fresh_outdoor_sensor_reading
    outdoor_ids = app_config.sensors.select { |s| s.type == :outdoor_meter }.map(&:id)
    return nil if outdoor_ids.empty?
    SensorReading
      .where(device_id: outdoor_ids)
      .where("taken_at >= ?", SENSOR_FRESHNESS.ago)
      .order(taken_at: :desc)
      .first
  rescue Errno::ENOENT
    nil
  end
end

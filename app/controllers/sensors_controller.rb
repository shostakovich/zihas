# app/controllers/sensors_controller.rb
class SensorsController < ApplicationController
  def index
    @sensors = app_config.sensors
    @latest  = SensorReading.latest_per_device(@sensors.map(&:id)).index_by(&:device_id)
  end

  def series
    since  = 24.hours.ago
    rows   = SensorReading.where(device_id: app_config.sensors.map(&:id)).since(since).order(:taken_at)
    grouped = rows.group_by(&:device_id)

    payload = {
      temperature: build_series(grouped, app_config.sensors, :temperature),
      humidity:    build_series(grouped, app_config.sensors, :humidity),
      co2:         build_series(grouped, app_config.sensors.select { |s| s.type == :meter_pro_co2 }, :co2),
    }
    render json: payload
  end

  private

  def build_series(grouped, sensors, attr)
    sensors.map do |s|
      points = (grouped[s.id] || []).map { |r| [ r.taken_at.to_i * 1000, r.public_send(attr) ] }.reject { |_, v| v.nil? }
      { device_id: s.id, name: s.name, points: points }
    end
  end
end

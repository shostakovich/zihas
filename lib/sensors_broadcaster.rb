require "config_loader"
require "weather_broadcaster"

module SensorsBroadcaster
  STREAM = "sensors".freeze

  module_function

  def refresh
    config = load_config
    return if config.nil? || config.sensors.empty?

    latest = SensorReading.latest_per_device(config.sensors.map(&:id)).index_by(&:device_id)

    Turbo::StreamsChannel.broadcast_replace_to(
      STREAM,
      target: "sensors_dashboard",
      partial: "sensors/dashboard",
      locals: { sensors: config.sensors, latest: latest }
    )

    WeatherBroadcaster.broadcast_current
  end

  def load_config
    ConfigLoader.app_config
  rescue ConfigLoader::Error
    nil
  end
end

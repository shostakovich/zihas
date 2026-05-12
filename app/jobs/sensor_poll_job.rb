require "switch_bot_client"
require "sensors_broadcaster"
require "config_loader"

class SensorPollJob < ApplicationJob
  queue_as :default

  def perform
    config = load_config
    return Rails.logger.info("sensors: not configured") if config.switchbot.nil? || config.sensors.empty?

    client = SwitchBotClient.new(token: config.switchbot.token, secret: config.switchbot.secret)
    now    = Time.current

    config.sensors.each do |sensor|
      begin
        data = client.device_status(sensor.id)
        SensorReading.create!(
          device_id:        sensor.id,
          taken_at:         now,
          temperature:      data[:temperature],
          humidity:         data[:humidity],
          co2:              data[:co2],
          battery_pct:      data[:battery_pct],
          firmware_version: data[:firmware_version],
        )
      rescue SwitchBotClient::Error => e
        Rails.logger.warn("SensorPoll[#{sensor.id}]: #{e.message}")
      end
    end

    TrmnlSensorPushJob.perform_later
    SensorsBroadcaster.refresh
  end

  private

  def load_config
    path = Rails.root.join("config", Rails.env.test? ? "ziwoas.test.yml" : "ziwoas.yml").to_s
    ConfigLoader.load(path)
  end
end

require "mqtt"
require "json"

# Web-side choke point for Govee commands. Publishes Home-Assistant JSON-light
# commands over a short-lived MQTT connection to govee2mqtt's per-device command
# topic. `state` is mandatory in every command: govee2mqtt rejects payloads
# without it, and brightness/color alone do not power a light on.
class GoveeCommander
  class Error < StandardError; end

  COMMAND_TOPIC        = "gv2mqtt/light/%s/command"
  SWITCH_COMMAND_TOPIC = "gv2mqtt/switch/%s/command/%s"

  def self.turn(light, on:, mqtt_config:, mqtt_factory: nil)
    publish(light, { "state" => (on ? "ON" : "OFF") }, mqtt_config:, mqtt_factory:)
  end

  def self.set_brightness(light, value:, mqtt_config:, mqtt_factory: nil)
    publish(light, { "state" => "ON", "brightness" => value.to_i }, mqtt_config:, mqtt_factory:)
  end

  def self.set_color(light, r:, g:, b:, mqtt_config:, mqtt_factory: nil)
    publish(light, { "state" => "ON", "color" => { "r" => r.to_i, "g" => g.to_i, "b" => b.to_i } },
            mqtt_config:, mqtt_factory:)
  end

  def self.set_color_temp(light, kelvin:, mqtt_config:, mqtt_factory: nil)
    publish(light, { "state" => "ON", "color_temp" => kelvin_to_mired(kelvin) },
            mqtt_config:, mqtt_factory:)
  end

  def self.set_effect(light, effect:, mqtt_config:, mqtt_factory: nil)
    publish(light, { "state" => "ON", "effect" => effect.to_s }, mqtt_config:, mqtt_factory:)
  end

  # Zone/power toggles are HA switch entities: raw "ON"/"OFF" payloads on a
  # per-instance command topic, NOT the JSON light command. `zone` is a toggle
  # instance key (e.g. "rippleLightToggle", "powerSwitch").
  def self.set_zone(light, zone:, on:, mqtt_config:, mqtt_factory: nil)
    publish_raw(format(SWITCH_COMMAND_TOPIC, light.key, zone), (on ? "ON" : "OFF"),
                light:, mqtt_config:, mqtt_factory:)
  end

  def self.kelvin_to_mired(kelvin) = (1_000_000.0 / kelvin.to_i).round

  def self.publish(light, payload, mqtt_config:, mqtt_factory: nil)
    publish_raw(format(COMMAND_TOPIC, light.key), JSON.generate(payload),
                light:, mqtt_config:, mqtt_factory:)
  end

  def self.publish_raw(topic, payload, light:, mqtt_config:, mqtt_factory: nil)
    factory = mqtt_factory || -> { MQTT::Client.new(host: mqtt_config.host, port: mqtt_config.port) }
    client  = factory.call
    begin
      client.connect
      client.publish(topic, payload)
    rescue StandardError => e
      raise Error, "MQTT publish for '#{light.key}' failed: #{e.class}: #{e.message}"
    ensure
      begin; client.disconnect; rescue StandardError; nil; end
    end
  end
end

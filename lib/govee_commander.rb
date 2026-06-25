require "mqtt"
require "json"

# Web-side choke point for Govee commands. Publishes over a short-lived MQTT
# connection; the GoveeMqttBridge translates these to UDP. Mirrors PlugCommander
# but does not persist a command log (LightState is the record of truth).
class GoveeCommander
  class Error < StandardError; end

  def self.turn(light, on:, source:, mqtt_config:, topic_prefix:, mqtt_factory: nil)
    new(mqtt_config: mqtt_config, topic_prefix: topic_prefix, mqtt_factory: mqtt_factory)
      .publish(light, "turn", { "on" => !!on })
  end

  def self.set_brightness(light, value:, source:, mqtt_config:, topic_prefix:, mqtt_factory: nil)
    new(mqtt_config: mqtt_config, topic_prefix: topic_prefix, mqtt_factory: mqtt_factory)
      .publish(light, "brightness", { "value" => value.to_i })
  end

  def self.set_color(light, r:, g:, b:, source:, mqtt_config:, topic_prefix:, mqtt_factory: nil)
    new(mqtt_config: mqtt_config, topic_prefix: topic_prefix, mqtt_factory: mqtt_factory)
      .publish(light, "color", { "r" => r.to_i, "g" => g.to_i, "b" => b.to_i })
  end

  def self.set_color_temp(light, kelvin:, source:, mqtt_config:, topic_prefix:, mqtt_factory: nil)
    new(mqtt_config: mqtt_config, topic_prefix: topic_prefix, mqtt_factory: mqtt_factory)
      .publish(light, "color_temp", { "temp_k" => kelvin.to_i })
  end

  def self.refresh(light, mqtt_config:, topic_prefix:, mqtt_factory: nil)
    new(mqtt_config: mqtt_config, topic_prefix: topic_prefix, mqtt_factory: mqtt_factory)
      .publish(light, "refresh", {})
  end

  def initialize(mqtt_config:, topic_prefix:, mqtt_factory: nil)
    @mqtt_config  = mqtt_config
    @topic_prefix = topic_prefix
    @mqtt_factory = mqtt_factory || -> {
      MQTT::Client.new(host: @mqtt_config.host, port: @mqtt_config.port)
    }
  end

  def publish(light, cmd, payload)
    client = @mqtt_factory.call
    begin
      client.connect
      client.publish("#{@topic_prefix}/#{light.key}/command/#{cmd}", JSON.generate(payload))
    rescue StandardError => e
      raise Error, "MQTT publish for '#{light.key}' failed: #{e.class}: #{e.message}"
    ensure
      begin; client.disconnect; rescue StandardError; nil; end
    end
  end
end

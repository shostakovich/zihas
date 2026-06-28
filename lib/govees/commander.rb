require "mqtt"
require "json"
require "govees/messages"

module Govees
  # Web-side choke point for govees commands: publishes a single `set` verb to
  # govees/<key>/set over a short-lived MQTT connection. The bridge does the rest
  # (routing, optimistic state, reconcile).
  class Commander
    class Error < StandardError; end

    SET_TOPIC = "govees/%s/set".freeze

    def self.turn(light, on:, **kw)               = publish(light, Messages::Set::Power.new(on: on).to_wire, **kw)
    def self.set_brightness(light, value:, **kw)  = publish(light, Messages::Set::Brightness.new(value: value).to_wire, **kw)
    def self.set_color(light, r:, g:, b:, **kw)   = publish(light, Messages::Set::Color.new(rgb: { r: r, g: g, b: b }).to_wire, **kw)
    def self.set_color_temp(light, kelvin:, **kw) = publish(light, Messages::Set::ColorTemp.new(kelvin: kelvin).to_wire, **kw)
    def self.set_zone(light, zone:, on:, **kw)    = publish(light, Messages::Set::Zone.new(name: zone, on: on).to_wire, **kw)
    def self.set_scene(light, scene:, **kw)       = publish(light, Messages::Set::Scene.new(name: scene).to_wire, **kw)

    def self.publish(light, verb, mqtt_config:, mqtt_factory: nil)
      factory = mqtt_factory || -> { MQTT::Client.new(host: mqtt_config.host, port: mqtt_config.port) }
      client  = factory.call
      begin
        client.connect
        client.publish(format(SET_TOPIC, light.key), JSON.generate(verb))
      rescue StandardError => e
        raise Error, "MQTT publish for '#{light.key}' failed: #{e.class}: #{e.message}"
      ensure
        begin; client.disconnect; rescue StandardError; nil; end
      end
    end
  end
end

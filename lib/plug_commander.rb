require "mqtt"

# The single choke point for switching plugs. Publishes over a short-lived
# MQTT connection and logs to switch_commands only after a successful publish.
class PlugCommander
  class Error < StandardError; end

  ACTIONS = %i[on off].freeze

  def self.switch(plug, action, source:, mqtt_config:)
    new(mqtt_config: mqtt_config).switch(plug, action, source: source)
  end

  def initialize(mqtt_config:, mqtt_factory: nil)
    @mqtt_config  = mqtt_config
    @mqtt_factory = mqtt_factory || -> {
      MQTT::Client.new(host: @mqtt_config.host, port: @mqtt_config.port)
    }
  end

  def switch(plug, action, source:)
    raise ArgumentError, "action must be one of #{ACTIONS}" unless ACTIONS.include?(action)
    raise Error, "plug '#{plug.id}' is not switchable" unless plug.switchable

    publish(plug, action)
    SwitchCommand.create!(plug_id: plug.id, action: action.to_s, source: source.to_s)
  end

  private

  def publish(plug, action)
    case plug.driver
    when :shelly then publish_shelly(plug, action)
    else raise Error, "no switch driver for '#{plug.driver}' (plug '#{plug.id}')"
    end
  end

  def publish_shelly(plug, action)
    client = @mqtt_factory.call
    begin
      client.connect
      client.publish("#{@mqtt_config.topic_prefix}/#{plug.id}/command/switch:0", action.to_s)
    rescue StandardError => e
      raise Error, "MQTT publish for '#{plug.id}' failed: #{e.class}: #{e.message}"
    ensure
      begin; client.disconnect; rescue StandardError; nil; end
    end
  end
end

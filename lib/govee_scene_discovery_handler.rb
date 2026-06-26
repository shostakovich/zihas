require "json"

# Consumes govee2mqtt's retained scene-select discovery config
# (gv2mqtt/select/<unique_id>/config where unique_id ends with "-mode-scene")
# and stores the device's firmware scene names on the matching Light. The
# device id is parsed from the config's command_topic
# (gv2mqtt/<id>/set-mode-scene) and equals the Light#key set by
# GoveeDiscoveryHandler. Non-scene selects (e.g. work mode) are ignored.
class GoveeSceneDiscoveryHandler
  PREFIX = "gv2mqtt/select/"

  def initialize(logger:)
    @logger = logger
  end

  def subscriptions = [ "#{PREFIX}+/config" ]

  def matches?(topic)
    topic.start_with?(PREFIX) && topic.end_with?("/config")
  end

  def handle(topic, payload)
    data = JSON.parse(payload)
    return unless data["unique_id"].to_s.end_with?("-mode-scene")

    key = device_id_from(data["command_topic"])
    return @logger.warn("GoveeSceneDiscoveryHandler: no usable command_topic on #{topic}") unless key

    light = Light.find_by(key: key)
    return @logger.warn("GoveeSceneDiscoveryHandler: no light for key #{key} on #{topic}") unless light

    light.update!(firmware_scenes: Array(data["options"]))
  rescue JSON::ParserError => e
    @logger.warn("GoveeSceneDiscoveryHandler: invalid JSON on #{topic}: #{e.message}")
  end

  private

  def device_id_from(command_topic)
    t = command_topic.to_s
    return nil unless t.start_with?("gv2mqtt/") && t.end_with?("/set-mode-scene")
    t.split("/")[1]
  end
end

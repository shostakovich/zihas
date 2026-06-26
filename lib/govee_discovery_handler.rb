require "json"

# Consumes govee2mqtt's retained Home-Assistant discovery configs
# (gv2mqtt/light/<unique_id>/config) and upserts Light rows, keyed by the bare
# device id parsed from the config's state_topic (the topic-path node is the
# unique_id "gv2mqtt-<id>", so we do NOT use it). Never deletes; sets name only
# on first create so user edits to name/room are preserved.
class GoveeDiscoveryHandler
  DISCOVERY_PREFIX = "gv2mqtt"

  def initialize(logger:)
    @logger = logger
  end

  def subscriptions = [ "#{DISCOVERY_PREFIX}/light/+/config" ]

  def matches?(topic)
    topic.start_with?("#{DISCOVERY_PREFIX}/light/") && topic.end_with?("/config")
  end

  def handle(topic, payload)
    data = JSON.parse(payload)
    key  = device_id_from(data["state_topic"])
    return @logger.warn("GoveeDiscoveryHandler: no state_topic in config on #{topic}") unless key

    light = Light.find_or_initialize_by(key: key)
    light.name = data["name"].presence || key if light.new_record?
    model = data.dig("device", "model")
    light.sku = model if model.present?
    modes = Array(data["supported_color_modes"])
    light.supports_color      = modes.include?("rgb")
    light.supports_color_temp = modes.include?("color_temp")
    light.save!
  rescue JSON::ParserError => e
    @logger.warn("GoveeDiscoveryHandler: invalid JSON on #{topic}: #{e.message}")
  end

  private

  def device_id_from(state_topic)
    t = state_topic.to_s
    return nil unless t.start_with?("gv2mqtt/light/") && t.end_with?("/state")
    t.split("/")[2]
  end
end

require "json"

# Consumes govee2mqtt's retained Home-Assistant discovery configs
# (gv2mqtt/light/<unique_id>/config) and upserts Light rows, keyed by the bare
# device id parsed from the config's state_topic (the topic-path node is the
# unique_id "gv2mqtt-<id>", so we do NOT use it). Never deletes; sets name only
# on first create so user edits to name/room are preserved.
# Scenes come from the effect_list field of the main-light discovery config —
# the select entity does not exist for these devices (gv2mqtt/select/… is never
# published), so firmware_scenes is populated here instead.
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
    # govee2mqtt puts the friendly name on the device block; the entity-level
    # "name" is null for the main light. Fall back to top-level name, then key.
    discovered_name = data.dig("device", "name").presence || data["name"].presence
    if light.new_record?
      light.name = discovered_name || key
    elsif discovered_name && discovered_name != key && light.name == light.key
      # Adopt a real name only while it is still the device-id placeholder;
      # user renames (name != key) are preserved.
      light.name = discovered_name
    end
    model = data.dig("device", "model")
    light.sku = model if model.present?
    modes = Array(data["supported_color_modes"])
    light.supports_color      = modes.include?("rgb")
    light.supports_color_temp = modes.include?("color_temp")
    effects = Array(data["effect_list"]).map(&:to_s).reject { |e| e.strip.empty? }
    light.firmware_scenes = effects if effects.any?
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

require "json"

# Consumes govee2mqtt's per-zone HA `switch` discovery configs
# (gv2mqtt/switch/<unique_id>/config) and stores the ordered list of *lighting*
# zone toggle keys on the matching Light. Only instances present in
# Light::ZONE_META are zones; control toggles (powerSwitch, dreamViewToggle,
# gradientToggle) are ignored. The device id is parsed from the command_topic
# (gv2mqtt/switch/<id>/command/<instance>) and equals Light#key. Never deletes;
# creates a placeholder-named Light if discovery order beats the light config.
class GoveeZoneDiscoveryHandler
  PREFIX = "gv2mqtt/switch/"

  def initialize(logger:)
    @logger = logger
  end

  def subscriptions = [ "#{PREFIX}+/config" ]

  def matches?(topic)
    topic.start_with?(PREFIX) && topic.end_with?("/config")
  end

  def handle(topic, payload)
    data = JSON.parse(payload)
    key, instance = parse(data["command_topic"])
    return unless key && instance
    return unless Light::ZONE_META.key?(instance)

    light = Light.find_or_initialize_by(key: key)
    light.name = key if light.new_record?
    light.zones = (light.zones + [ instance ]).uniq
    light.save!
  rescue JSON::ParserError => e
    @logger.warn("GoveeZoneDiscoveryHandler: invalid JSON on #{topic}: #{e.message}")
  end

  private

  # "gv2mqtt/switch/<id>/command/<instance>" -> ["<id>", "<instance>"]
  def parse(command_topic)
    t = command_topic.to_s.split("/")
    return [ nil, nil ] unless t.length == 5 && t[0] == "gv2mqtt" && t[1] == "switch" && t[3] == "command"
    [ t[2], t[4] ]
  end
end

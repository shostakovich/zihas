# Consumes per-zone HA switch state (gv2mqtt/switch/<id>/<instance>/state =
# "ON"/"OFF") for lighting zones and reflects each bit into
# LightState#zone_states, broadcasting the change on the "dashboard" stream.
# Only Light::ZONE_META instances are tracked; powerSwitch (whole-lamp power)
# is left to GoveeStatusHandler via the light state topic.
class GoveeZoneStateHandler
  PREFIX = "gv2mqtt/switch/"

  def initialize(logger:)
    @logger = logger
  end

  def subscriptions = [ "#{PREFIX}+/+/state" ]

  def matches?(topic)
    parts = topic.split("/")
    parts.length == 5 && parts[0] == "gv2mqtt" && parts[1] == "switch" && parts[4] == "state"
  end

  def handle(topic, payload)
    _, _, key, instance, _ = topic.split("/")
    return unless Light::ZONE_META.key?(instance)

    on = payload.to_s.strip == "ON"
    LightState.record_zone_state(key, instance, on)
    broadcast(key, instance, on)
  end

  private

  def broadcast(key, instance, on)
    ActionCable.server.broadcast("dashboard",
      { lights: [ { light_key: key, zones: { instance => on } } ] })
  rescue => e
    @logger.warn("GoveeZoneStateHandler: broadcast failed: #{e.message}")
  end
end

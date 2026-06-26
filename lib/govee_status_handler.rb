require "json"

# Consumes govee2mqtt's HA-JSON light state (gv2mqtt/light/<id>/state) and the
# global availability topic (gv2mqtt/availability). Upserts LightState keyed by
# the device id and broadcasts changes on the "dashboard" ActionCable stream.
class GoveeStatusHandler
  STATE_PREFIX     = "gv2mqtt/light/"
  AVAILABILITY     = "gv2mqtt/availability"
  BROADCAST_FIELDS = %i[on brightness color_r color_g color_b color_temp_k reachable].freeze

  def initialize(logger:)
    @logger = logger
  end

  def subscriptions = [ "gv2mqtt/light/+/state", AVAILABILITY ]

  def matches?(topic)
    topic == AVAILABILITY || (topic.start_with?(STATE_PREFIX) && topic.end_with?("/state"))
  end

  def handle(topic, payload)
    return handle_availability(payload) if topic == AVAILABILITY
    handle_state(topic, payload)
  end

  private

  def handle_state(topic, payload)
    key   = topic.split("/")[2]
    data  = JSON.parse(payload)
    attrs = parse_state(data).merge(last_seen_at: Time.current)
    LightState.record_state(key, attrs)
    broadcast(key, attrs)
  rescue JSON::ParserError => e
    @logger.warn("GoveeStatusHandler: invalid JSON on #{topic}: #{e.message}")
  end

  # "offline" means govee2mqtt is gone (its LWT): mark every light unreachable.
  # "online" is a no-op; per-device state refreshes naturally.
  def handle_availability(payload)
    return unless payload.to_s.strip == "offline"
    LightState.where(reachable: true).update_all(reachable: false)
    broadcast_all_unreachable
  end

  # State is mode-dependent: rgb mode carries "color"; color_temp mode carries
  # "color_temp" (mireds); never both. Absent fields stay out of attrs so we
  # never clobber the other mode's last-known values.
  def parse_state(data)
    attrs = { on: data["state"] == "ON", reachable: true }
    attrs[:brightness] = data["brightness"] if data.key?("brightness")
    if (c = data["color"])
      attrs[:color_r] = c["r"]; attrs[:color_g] = c["g"]; attrs[:color_b] = c["b"]
    end
    attrs[:color_temp_k] = mired_to_kelvin(data["color_temp"]) if data["color_temp"]
    attrs
  end

  def mired_to_kelvin(mired) = (1_000_000.0 / mired.to_i).round

  def broadcast(key, attrs)
    payload = attrs.slice(*BROADCAST_FIELDS).merge(light_key: key)
    ActionCable.server.broadcast("dashboard", { lights: [ payload ] })
  rescue => e
    @logger.warn("GoveeStatusHandler: ActionCable broadcast failed: #{e.message}")
  end

  def broadcast_all_unreachable
    lights = LightState.all.map { |s| { light_key: s.light_key, reachable: false } }
    ActionCable.server.broadcast("dashboard", { lights: lights }) if lights.any?
  rescue => e
    @logger.warn("GoveeStatusHandler: ActionCable broadcast failed: #{e.message}")
  end
end

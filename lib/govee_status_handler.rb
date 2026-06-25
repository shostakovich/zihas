require "json"

# Consumes govee/<key>/status messages: upserts LightState and broadcasts the
# new state to the switches page over the "dashboard" ActionCable stream.
class GoveeStatusHandler
  FIELDS = %i[on brightness color_r color_g color_b color_temp_k reachable].freeze

  def initialize(topic_prefix:, logger:)
    @topic_prefix = topic_prefix
    @logger       = logger
  end

  def subscriptions = [ "#{@topic_prefix}/+/status" ]

  def matches?(topic)
    topic.start_with?("#{@topic_prefix}/") && topic.end_with?("/status")
  end

  def handle(topic, payload)
    key  = topic.split("/")[1]
    data = JSON.parse(payload)
    attrs = FIELDS.to_h { |f| [ f, data[f.to_s] ] }
    attrs[:last_seen_at] = Time.current
    LightState.record_state(key, attrs)
    fill_sku(key, data["sku"])
    broadcast(key, attrs)
  rescue JSON::ParserError => e
    @logger.warn("GoveeStatusHandler: invalid JSON on #{topic}: #{e.message}")
  end

  private

  def fill_sku(key, sku)
    return if sku.blank?
    Light.where(key: key, sku: nil).update_all(sku: sku)
  end

  def broadcast(key, attrs)
    ActionCable.server.broadcast("dashboard", { lights: [ attrs.slice(*FIELDS).merge(light_key: key) ] })
  rescue => e
    @logger.warn("GoveeStatusHandler: ActionCable broadcast failed: #{e.message}")
  end
end

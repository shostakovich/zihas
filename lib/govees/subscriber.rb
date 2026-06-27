require "json"

module Govees
  # The ziwoas-facing counterpart of the bridge: the single MQTT handler that
  # consumes govees/<key>/config (Light upsert) and govees/<key>/state
  # (LightState + broadcasts). Native units (brightness 0-100, Kelvin, rgb);
  # absent state fields are left untouched. Implements the MqttRouter contract.
  class Subscriber
    PREFIX = "govees/"

    def initialize(logger:)
      @logger = logger
    end

    def subscriptions = [ "govees/+/config", "govees/+/state" ]

    def matches?(topic)
      topic.start_with?(PREFIX) && (topic.end_with?("/config") || topic.end_with?("/state"))
    end

    def handle(topic, payload)
      if topic.end_with?("/config") then handle_config(topic, payload)
      elsif topic.end_with?("/state") then handle_state(topic, payload)
      end
    end

    private

    def handle_config(topic, payload)
      key  = topic.split("/")[1]
      data = JSON.parse(payload)
      light = Light.find_or_initialize_by(key: key)
      name = data["name"].to_s
      light.name = name.presence || key if light.new_record?
      light.sku = data["sku"] if data["sku"].present?
      light.supports_color      = !!data["supports_color"]
      light.supports_color_temp = !!data["supports_color_temp"]
      light.zones           = Array(data["zones"]).map(&:to_s)
      light.firmware_scenes = Array(data["scenes"]).map(&:to_s)
      room_name = data["room"].to_s.presence
      light.room = Room.find_or_create_by!(name: room_name) if room_name
      light.save!
    rescue JSON::ParserError => e
      @logger.warn("Govees::Subscriber: invalid config JSON on #{topic}: #{e.message}")
    end

    def handle_state(topic, payload)
      key   = topic.split("/")[1]
      data  = JSON.parse(payload)
      attrs = parse_state(data).merge(last_seen_at: Time.current)
      LightState.record_state(key, attrs)
      data["zone_states"].each { |inst, on| LightState.record_zone_state(key, inst, !!on) } if data["zone_states"].is_a?(Hash)
      broadcast_turbo(key)
    rescue JSON::ParserError => e
      @logger.warn("Govees::Subscriber: invalid state JSON on #{topic}: #{e.message}")
    end

    def parse_state(data)
      attrs = { on: !!data["on"], reachable: data.key?("reachable") ? !!data["reachable"] : true }
      attrs[:brightness] = data["brightness"] if data.key?("brightness")
      if (c = data["color"])
        attrs[:color_r] = c["r"]; attrs[:color_g] = c["g"]; attrs[:color_b] = c["b"]
      end
      attrs[:color_temp_k] = data["color_temp_k"] if data["color_temp_k"]
      attrs
    end

    # Reconcile both views from one MQTT state message: the detail page hero
    # (#light_power on the per-light stream) and the /switches list card
    # (#light_card_<key> on the shared "lights" stream). Both pages render
    # server-side, so neither needs Stimulus/ActionCable JS.
    def broadcast_turbo(key)
      light = Light.find_by(key: key)
      return unless light
      row = LightRow.new(light: light, state: LightState.find_by(light_key: key))
      Turbo::StreamsChannel.broadcast_replace_to("light_#{key}",
        target: "light_power", partial: "lights/power", locals: { light: light, row: row })
      Turbo::StreamsChannel.broadcast_replace_to("lights",
        target: "light_card_#{key}", partial: "switches/light_card", locals: { row: row })
    rescue => e
      @logger.warn("Govees::Subscriber: turbo broadcast failed: #{e.message}")
    end
  end
end

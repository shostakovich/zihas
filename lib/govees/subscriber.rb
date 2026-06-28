require "json"
require "govees/messages"

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
      cfg  = Messages::Config.from_hash(JSON.parse(payload))
      light = Light.find_or_initialize_by(key: key)
      light.name = cfg.name.presence || key if light.new_record?
      light.sku = cfg.sku if cfg.sku.present?
      light.supports_color      = cfg.supports_color
      light.supports_color_temp = cfg.supports_color_temp
      light.zones           = cfg.zones
      light.firmware_scenes = cfg.scenes
      light.save!
    rescue JSON::ParserError, Dry::Struct::Error, ActiveRecord::ActiveRecordError => e
      @logger.warn("Govees::Subscriber: invalid config on #{topic}: #{e.message}")
    end

    def handle_state(topic, payload)
      key   = topic.split("/")[1]
      msg   = Messages::State.from_hash(JSON.parse(payload))
      LightState.record_state(key, state_attrs(msg).merge(last_seen_at: Time.current))
      msg.zone_states.each { |inst, on| LightState.record_zone_state(key, inst, on) } if msg.attributes.key?(:zone_states)
      broadcast_turbo(key)
    rescue JSON::ParserError, Dry::Struct::Error, ActiveRecord::ActiveRecordError => e
      @logger.warn("Govees::Subscriber: invalid state on #{topic}: #{e.message}")
    end

    def state_attrs(msg)
      attrs = { on: msg.on, reachable: msg.reachable }
      attrs[:brightness] = msg.brightness if msg.attributes.key?(:brightness)
      if msg.attributes.key?(:color)
        attrs[:color_r] = msg.color.r; attrs[:color_g] = msg.color.g; attrs[:color_b] = msg.color.b
      end
      attrs[:color_temp_k] = msg.color_temp_k if msg.attributes.key?(:color_temp_k)
      attrs
    end

    # Reconcile both views from one MQTT state message: the detail page hero
    # (#light_power on the per-light stream) and the /switches list card
    # (#light_card_<key> on the shared "lights" stream). Both pages render
    # server-side, so neither needs Stimulus/ActionCable JS.
    def broadcast_turbo(key)
      light = Light.find_by(key: key)
      return unless light
      snapshot = LightSnapshot.new(light: light, state: LightState.find_by(light_key: key))
      # layout: false is required: the channel-level broadcast (unlike the model
      # mixin) does not disable the layout for `renderable:`, so without it the
      # component is wrapped in the full app layout (header + nav) and replacing
      # #light_power injects a duplicate navigation into the page.
      Turbo::StreamsChannel.broadcast_replace_to("light_#{key}",
        target: "light_power", renderable: Lights::PowerComponent.new(snapshot: snapshot), layout: false)
      Turbo::StreamsChannel.broadcast_replace_to("lights",
        target: "light_card_#{key}", renderable: Lights::LightCardComponent.new(snapshot: snapshot), layout: false)
    rescue => e
      @logger.warn("Govees::Subscriber: turbo broadcast failed: #{e.message}")
    end
  end
end

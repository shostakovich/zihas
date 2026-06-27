require "json"

module Govees
  # The ziwoas-facing counterpart of the bridge: the single MQTT handler that
  # consumes govees/<key>/config and govees/<key>/state. This task implements the
  # config side (Light upsert, curated scenes/zones from the bridge); Task 10 adds
  # state. Implements the MqttRouter handler contract.
  class Subscriber
    PREFIX = "govees/"

    def initialize(logger:)
      @logger = logger
    end

    def subscriptions = [ "govees/+/config" ]

    def matches?(topic)
      topic.start_with?(PREFIX) && topic.end_with?("/config")
    end

    def handle(topic, payload)
      return handle_config(topic, payload) if topic.end_with?("/config")
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
      light.save!
    rescue JSON::ParserError => e
      @logger.warn("Govees::Subscriber: invalid config JSON on #{topic}: #{e.message}")
    end
  end
end

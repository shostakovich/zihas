# lib/govees/messages.rb
require "dry/struct"
require "govees/types"

module Govees
  # Typed MQTT wire contracts shared by both ends. Each struct can build itself
  # from a raw hash (consumer side) and emit its canonical wire hash (producer
  # side). transform_keys(&:to_sym) lets every struct accept the string-keyed
  # JSON hashes that arrive off the wire.
  module Messages
    class Base < Dry::Struct
      transform_keys(&:to_sym)
    end

    class Rgb < Base
      attribute :r, Types::RgbComponent
      attribute :g, Types::RgbComponent
      attribute :b, Types::RgbComponent
      def to_wire = { "r" => r, "g" => g, "b" => b }
    end

    # The published per-lamp snapshot. on/reachable mirror the Subscriber's
    # historical defaults (absent on => false, absent reachable => true); the
    # rest are partial. nil-valued fields are dropped (the store uses
    # color/color_temp_k = nil to clear the other), which the sole consumer
    # already ignores.
    class State < Base
      attribute  :on,           Types::Bool.default(false)
      attribute  :reachable,    Types::Bool.default(true)
      attribute? :brightness,   Types::Brightness
      attribute? :color,        Rgb
      attribute? :color_temp_k, Types::Kelvin
      attribute? :zone_states,  Types::Hash.map(Types::ZoneName, Types::Bool)

      def self.from_hash(h)
        new(h.transform_keys(&:to_sym).reject { |_, v| v.nil? })
      end

      def to_wire
        w = { "on" => on, "reachable" => reachable }
        w["brightness"]   = brightness    if attributes.key?(:brightness)
        w["color"]        = color.to_wire if attributes.key?(:color)
        w["color_temp_k"] = color_temp_k  if attributes.key?(:color_temp_k)
        w["zone_states"]  = zone_states   if attributes.key?(:zone_states)
        w
      end
    end

    # Device capabilities advertised on govees/<key>/config.
    class Config < Base
      attribute :sku,                 Types::String.default("".freeze)
      attribute :name,                Types::String.default("".freeze)
      attribute :supports_color,      Types::Bool.default(false)
      attribute :supports_color_temp, Types::Bool.default(false)
      attribute :zones,               Types::Array.of(Types::ZoneName).default([].freeze)
      attribute :scenes,              Types::Array.of(Types::SceneName).default([].freeze)

      def self.from_device(device)
        new(sku: device.sku, name: device.name,
            supports_color: device.supports_color, supports_color_temp: device.supports_color_temp,
            zones: device.zones, scenes: device.scenes)
      end

      def self.from_hash(h) = new(h.transform_keys(&:to_sym).reject { |_, v| v.nil? })

      def to_wire
        { "sku" => sku, "name" => name,
          "supports_color" => supports_color, "supports_color_temp" => supports_color_temp,
          "zones" => zones, "scenes" => scenes }
      end
    end

    # Typisierte Sicht auf die rohe Platform-API-Capability-Map
    # ({instance => value}). Kapselt die Konvertierung in Telemetrie.
    class DeviceState < Base
      attribute  :on,           Types::Bool.default(false)
      attribute  :reachable,    Types::Bool.default(true)
      attribute? :brightness,   Types::Brightness
      attribute? :color,        Rgb
      attribute? :color_temp_k, Types::Kelvin
      attribute? :zone_states,  Types::Hash.map(Types::ZoneName, Types::Bool)

      def self.from_capabilities(map, zone_keys:)
        online = map.fetch("online", true)
        attrs = { on: map["powerSwitch"].to_i == 1, reachable: (online == true || online == 1) }
        attrs[:brightness] = map["brightness"] if map.key?("brightness")
        if map["colorRgb"].to_i.positive?
          rgb = map["colorRgb"].to_i
          attrs[:color] = { r: (rgb >> 16) & 0xFF, g: (rgb >> 8) & 0xFF, b: rgb & 0xFF }
        elsif map["colorTemperatureK"].to_i.positive?
          attrs[:color_temp_k] = map["colorTemperatureK"]
        end
        zones = zone_keys.each_with_object({}) do |z, h|
          v = map[z]
          h[z] = (v.to_i == 1) unless v.nil? || v == ""
        end
        attrs[:zone_states] = zones unless zones.empty?
        new(attrs)
      end

      def to_telemetry
        t = { on: on, reachable: reachable }
        t[:brightness]   = brightness    if attributes.key?(:brightness)
        t[:color]        = { r: color.r, g: color.g, b: color.b } if attributes.key?(:color)
        t[:color_temp_k] = color_temp_k  if attributes.key?(:color_temp_k)
        t[:zone_states]  = zone_states   if attributes.key?(:zone_states)
        t
      end
    end

    module Set
      class Power < Base
        attribute :on, Types::Bool
        def to_wire = { "power" => (on ? "on" : "off") }
      end

      class Brightness < Base
        attribute :value, Types::Brightness
        def to_wire = { "brightness" => value }
      end

      class Color < Base
        attribute :rgb, Rgb
        def to_wire = { "color" => rgb.to_wire }
      end

      class ColorTemp < Base
        attribute :kelvin, Types::Kelvin
        def to_wire = { "color_temp_k" => kelvin }
      end

      class Zone < Base
        attribute :name, Types::ZoneName
        attribute :on,   Types::Bool
        def to_wire = { "zone" => { "name" => name, "on" => on } }
      end

      class Scene < Base
        attribute :name, Types::SceneName
        def to_wire = { "scene" => name }
      end

      # Raw verb hash -> one Set struct, or nil for an unknown verb.
      def self.parse(hash)
        h = hash.transform_keys(&:to_s)
        # "power" arrives as the wire strings "on"/"off"; Types::Bool (params.bool) coerces them.
        if    h.key?("power")        then Power.new(on: h["power"])
        elsif h.key?("brightness")   then Brightness.new(value: h["brightness"])
        elsif h.key?("color")        then Color.new(rgb: h["color"])
        elsif h.key?("color_temp_k") then ColorTemp.new(kelvin: h["color_temp_k"])
        elsif h.key?("zone")         then Zone.new(h["zone"])
        elsif h.key?("scene")        then Scene.new(name: h["scene"])
        end
      end
    end
  end
end

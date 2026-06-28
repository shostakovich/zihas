# lib/govees/device_registry.rb
require "govees/device"

module Govees
  # Builds the canonical lamp list from the Platform API (authoritative for
  # id/sku/name/capabilities/scenes) and curates it: segments dropped, zones
  # limited to Light::ZONE_META keys, scenes reduced to names + an internal
  # name->{id,paramId} index. LAN discovery only contributes the IP.
  class DeviceRegistry
    def initialize(api:, logger:, names: {})
      @api    = api
      @logger = logger
      # Normalize keys up-front so lookups work regardless of separator style.
      @names  = names.transform_keys { |k| self.class.normalize_mac(k.to_s) }
      @by_key = {}
    end

    def self.normalize_mac(str) = str.to_s.gsub(/[^0-9A-Za-z]/, "").upcase

    # Govee exposes DreamView scene groups as virtual "devices" (only a
    # powerSwitch, no LAN presence). They are scenes, not lamps — never publish
    # them as lights.
    VIRTUAL_SKUS = %w[DreamViewScenic].freeze

    # Build the new map fully, then swap @by_key by reference. The swap is
    # atomic under the GVL, so concurrent readers (listener/command/pollers)
    # always see a complete map — never a half-built one. On failure the old
    # map is kept, so a transient API hiccup never wipes the registry.
    def refresh!
      built = {}
      @api.devices.each do |raw|
        device = build(raw)
        next unless device
        # Preserve a previously discovered LAN IP across refreshes (copy-on-write).
        prev_ip = @by_key[device.key]&.ip
        built[device.key] = prev_ip ? device.new(ip: prev_ip) : device
      end
      @by_key = built
      all
    rescue => e
      @logger.warn("Govees::DeviceRegistry: refresh failed: #{e.class}: #{e.message}")
      all
    end

    def all          = @by_key.values
    def find(key)    = @by_key[key]
    def find_by_mac(mac) = @by_key[self.class.normalize_mac(mac)]

    def record_lan_ip(mac, ip)
      d = find_by_mac(mac)
      @by_key[d.key] = d.new(ip: ip) if d
    end

    private

    def build(raw)
      api_id = raw["device"].to_s
      return nil if api_id.empty?
      return nil if VIRTUAL_SKUS.include?(raw["sku"].to_s)
      key        = self.class.normalize_mac(api_id)
      override   = @names[key]
      caps       = Array(raw["capabilities"])
      instances  = caps.map { |c| c["instance"] }
      power_only = instances == [ "powerSwitch" ]
      zones      = instances & Light::ZONE_META.keys
      scenes, index = power_only ? [ [], {} ] : load_scenes(raw)

      Device.new(
        key: key, api_id: api_id, sku: raw["sku"].to_s,
        name: (override && override[:name].presence) || raw["deviceName"].to_s,
        ip: nil,
        supports_color:      instances.include?("colorRgb"),
        supports_color_temp: instances.include?("colorTemperatureK"),
        zones: zones, scenes: scenes, scene_index: index, power_only: power_only)
    end

    def load_scenes(raw)
      options = @api.scenes(sku: raw["sku"], device: raw["device"])
      names = []
      index = {}
      Array(options).each do |opt|
        name = opt["name"].to_s
        next if name.empty?
        names << name
        index[name] = { id: opt.dig("value", "id"), param_id: opt.dig("value", "paramId") }
      end
      [ names, index ]
    rescue => e
      @logger.warn("Govees::DeviceRegistry: scenes for #{raw['device']} failed: #{e.message}")
      [ [], {} ]
    end
  end
end

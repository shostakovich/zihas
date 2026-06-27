# lib/govees/reconciler.rb
require "govees/state_store"

module Govees
  # Drives reconcile: LAN devStatus readings (fast) and API polls (slow, richer).
  # Pure mapping helpers are class methods; instance methods wire them to the
  # store and trigger API clarification when a LAN reading deviates.
  class Reconciler
    def initialize(registry:, lan:, api:, store:, logger:)
      @registry = registry; @lan = lan; @api = api; @store = store; @logger = logger
    end

    def self.lan_to_telemetry(status)
      t = { on: status.on, reachable: true }
      t[:brightness] = status.brightness unless status.brightness.nil?
      if status.color_temp_k.to_i.positive?
        t[:color_temp_k] = status.color_temp_k
      elsif status.color_r
        t[:color] = { r: status.color_r, g: status.color_g, b: status.color_b }
      end
      t
    end

    def self.api_to_telemetry(state, device)
      online = state.fetch("online", true)
      t = { on: state["powerSwitch"].to_i == 1, reachable: (online == true || online == 1) }
      t[:brightness] = state["brightness"] if state.key?("brightness")
      if state["colorRgb"].to_i.positive?
        rgb = state["colorRgb"].to_i
        t[:color] = { r: (rgb >> 16) & 0xFF, g: (rgb >> 8) & 0xFF, b: rgb & 0xFF }
      elsif state["colorTemperatureK"].to_i.positive?
        t[:color_temp_k] = state["colorTemperatureK"]
      end
      zones = device.zones.each_with_object({}) do |z, h|
        v = state[z]
        h[z] = (v.to_i == 1) unless v.nil? || v == ""
      end
      t[:zone_states] = zones unless zones.empty?
      t
    end

    # Called when a LAN devStatus reply for `key` arrives (via the Bridge listener).
    def apply_lan(key, status)
      res = @store.apply_telemetry(key, self.class.lan_to_telemetry(status), source: :lan)
      clarify(key) if res[:needs_api_clarification]
      res
    end

    # Periodic full reconcile against the API.
    def api_tick
      @registry.all.map do |device|
        state = @api.state(sku: device.sku, device: device.api_id)
        [ device.key, @store.apply_telemetry(device.key, self.class.api_to_telemetry(state, device), source: :api) ]
      rescue => e
        @logger.warn("Govees::Reconciler: api_tick #{device.key}: #{e.message}")
        [ device.key, nil ]
      end
    end

    def clarify(key)
      device = @registry.find(key)
      return unless device
      state = @api.state(sku: device.sku, device: device.api_id)
      @store.apply_telemetry(key, self.class.api_to_telemetry(state, device), source: :api)
    rescue => e
      @logger.warn("Govees::Reconciler: clarify #{key}: #{e.message}")
    end
  end
end

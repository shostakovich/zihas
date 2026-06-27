# lib/govees/command_router.rb
require "govees/state_store"

module Govees
  # Translates one parsed `govees/<id>/set` verb into a LAN or API call per
  # capability, and records the optimistic state. Power/brightness/colour/temp
  # prefer LAN (when an IP is known); zones and scenes are API-only.
  class CommandRouter
    ON_OFF = "devices.capabilities.on_off".freeze
    TOGGLE = "devices.capabilities.toggle".freeze
    SCENE  = "devices.capabilities.dynamic_scene".freeze

    def initialize(registry:, lan:, api:, store:, logger:)
      @registry = registry; @lan = lan; @api = api; @store = store; @logger = logger
    end

    def handle(key, verb)
      device = @registry.find(key)
      unless device
        @logger.warn("Govees::CommandRouter: unknown device #{key}")
        return nil
      end
      verb = verb.transform_keys(&:to_s)

      changes =
        if verb.key?("power")         then power(device, verb["power"].to_s == "on")
        elsif verb.key?("brightness") then brightness(device, verb["brightness"].to_i)
        elsif verb.key?("color")      then color(device, verb["color"])
        elsif verb.key?("color_temp_k") then color_temp(device, verb["color_temp_k"].to_i)
        elsif verb.key?("zone")       then zone(device, verb["zone"])
        elsif verb.key?("scene")      then scene(device, verb["scene"].to_s)
        else
          @logger.warn("Govees::CommandRouter: unknown verb #{verb.keys}")
          return nil
        end

      @store.record_command(key, changes)
    end

    private

    def lan?(device) = device.ip && !device.power_only

    def power(device, on)
      if lan?(device)
        @lan.turn(device.ip, on); @lan.request_status(device.ip)
      else
        @api.control(sku: device.sku, device: device.api_id, type: ON_OFF, instance: "powerSwitch", value: on ? 1 : 0)
      end
      { on: on }
    end

    def brightness(device, value)
      if lan?(device)
        @lan.brightness(device.ip, value); @lan.request_status(device.ip)
      else
        @api.control(sku: device.sku, device: device.api_id, type: "devices.capabilities.range", instance: "brightness", value: value)
      end
      { on: true, brightness: value }
    end

    def color(device, rgb)
      rgb = rgb.transform_keys(&:to_s)
      r, g, b = rgb["r"].to_i, rgb["g"].to_i, rgb["b"].to_i
      if lan?(device)
        @lan.color(device.ip, r: r, g: g, b: b); @lan.request_status(device.ip)
      else
        @api.control(sku: device.sku, device: device.api_id, type: "devices.capabilities.color_setting",
                     instance: "colorRgb", value: (r << 16) | (g << 8) | b)
      end
      { on: true, color: { r: r, g: g, b: b }, color_temp_k: nil }
    end

    def color_temp(device, kelvin)
      if lan?(device)
        @lan.color_temp(device.ip, kelvin); @lan.request_status(device.ip)
      else
        @api.control(sku: device.sku, device: device.api_id, type: "devices.capabilities.color_setting",
                     instance: "colorTemperatureK", value: kelvin)
      end
      { on: true, color_temp_k: kelvin, color: nil }
    end

    def zone(device, spec)
      spec = spec.transform_keys(&:to_s)
      name = spec["name"].to_s
      on   = spec["on"] ? true : false
      @api.control(sku: device.sku, device: device.api_id, type: TOGGLE, instance: name, value: on ? 1 : 0)
      bits = (@store.published(device.key) || {})[:zone_states] || {}
      { zone_states: bits.merge(name => on) }
    end

    def scene(device, name)
      entry = device.scene_index[name]
      return {} unless entry
      @api.control(sku: device.sku, device: device.api_id, type: SCENE, instance: "lightScene",
                   value: { "id" => entry[:id], "paramId" => entry[:param_id] })
      { on: true }
    end
  end
end

# lib/govees/command_router.rb
require "govees/state_store"
require "govees/messages"

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

      cmd = Messages::Set.parse(verb)
      unless cmd
        @logger.warn("Govees::CommandRouter: unknown verb #{verb.keys}")
        return nil
      end

      changes =
        case cmd
        when Messages::Set::Power      then power(device, cmd.on)
        when Messages::Set::Brightness then brightness(device, cmd.value)
        when Messages::Set::Color      then color(device, cmd.rgb)
        when Messages::Set::ColorTemp  then color_temp(device, cmd.kelvin)
        when Messages::Set::Zone       then zone(device, cmd)
        when Messages::Set::Scene      then scene(device, cmd.name)
        end

      return nil if changes.nil? || changes.empty?

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
      r, g, b = rgb.r, rgb.g, rgb.b
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

    def zone(device, cmd)
      name = cmd.name
      on   = cmd.on
      @api.control(sku: device.sku, device: device.api_id, type: TOGGLE, instance: name, value: on ? 1 : 0)
      bits = (@store.published(device.key) || {})[:zone_states] || {}
      changes = { zone_states: bits.merge(name => on) }
      # powerSwitch IS the power capability (reconciler derives on:=powerSwitch==1);
      # keep the canonical `on` field in sync so optimistic state isn't stale.
      changes[:on] = on if name == "powerSwitch"
      changes
    end

    def scene(device, name)
      entry = device.scene_index[name]
      unless entry
        @logger.warn("Govees::CommandRouter: unknown scene '#{name}' for #{device.key}")
        return {}
      end
      @api.control(sku: device.sku, device: device.api_id, type: SCENE, instance: "lightScene",
                   value: { "id" => entry[:id], "paramId" => entry[:param_id] })
      { on: true }
    end
  end
end

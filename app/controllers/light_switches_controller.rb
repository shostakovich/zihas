# app/controllers/light_switches_controller.rb
require "govees/commander"

class LightSwitchesController < ApplicationController
  def create
    light = Light.find_by(key: params[:light_key])
    return head :not_found unless light

    case params[:command]
    when "turn"
      on = cast_bool(params[:on])
      if light.zone_lamp?
        Govees::Commander.set_zone(light, zone: "powerSwitch", on: on, **opts)
      else
        Govees::Commander.turn(light, on: on, **opts)
      end
      LightState.record_state(light.key, on: on)
      return respond_power(light)
    when "zone"
      return head :unprocessable_entity unless light.zones.include?(params[:zone])
      on = cast_bool(params[:on])
      evicted = on ? evict_for(light, params[:zone]) : nil
      if evicted
        LightState.record_zone_state(light.key, evicted, false)
        Govees::Commander.set_zone(light, zone: evicted, on: false, **opts)
      end
      LightState.record_zone_state(light.key, params[:zone], on)
      Govees::Commander.set_zone(light, zone: params[:zone], on: on, **opts)
      if evicted
        toast = { message: "#{Light::ZONE_META.dig(evicted, :label)} ausgeschaltet · max. #{light.max_active_zones} Zonen",
                  undo: { light_key: light.key, victim: evicted, added: params[:zone] } }
        return respond_zone(light, params[:zone], evicted, toast: toast)
      end
      return respond_zone(light, params[:zone])
    when "brightness"
      Govees::Commander.set_brightness(light, value: params[:value].to_i, **opts)
    when "color"
      Govees::Commander.set_color(light, r: params[:r].to_i, g: params[:g].to_i, b: params[:b].to_i, **opts)
    when "color_temp"
      Govees::Commander.set_color_temp(light, kelvin: params[:temp_k].to_i, **opts)
    when "effect", "scene"
      Govees::Commander.set_scene(light, scene: params[:effect] || params[:scene], **opts)
    when "zone_undo"
      victim = params[:victim]; added = params[:added]
      return head :unprocessable_entity unless light.zones.include?(victim) && light.zones.include?(added)
      LightState.record_zone_state(light.key, victim, true)
      Govees::Commander.set_zone(light, zone: victim, on: true, **opts)
      LightState.record_zone_state(light.key, added, false)
      Govees::Commander.set_zone(light, zone: added, on: false, **opts)
      return respond_zone(light, victim, added, toast: { message: nil, undo: nil })
    else
      return head :unprocessable_entity
    end

    head :no_content
  rescue Govees::Commander::Error
    head :service_unavailable
  end

  private

  def opts = { mqtt_config: app_config.mqtt }
  def cast_bool(v) = ActiveModel::Type::Boolean.new.cast(v)

  # Render both targets: the detail page hero (#light_power) and the /switches
  # list card (#light_card_<key>). Turbo only applies the action whose target
  # exists in the current DOM, so one endpoint serves both pages without JS.
  def respond_power(light)
    row = LightRow.new(light: light, state: LightState.find_by(light_key: light.key))
    render turbo_stream: [
      turbo_stream.replace("light_power", partial: "lights/power", locals: { light: light, row: row }),
      turbo_stream.replace("light_card_#{light.key}", partial: "switches/light_card", locals: { row: row })
    ]
  end

  def evict_for(light, zone)
    return nil unless Light::ZONE_META.dig(zone, :role) == "side"
    max = light.max_active_zones.to_i
    return nil unless max.positive?
    bits = LightState.find_by(light_key: light.key)&.zone_states || {}
    on_zones = light.zones.select { |z| bits[z] } - [ zone ]
    return nil if on_zones.size < max
    on_zones.find { |z| Light::ZONE_META.dig(z, :role) == "side" }
  end

  def respond_zone(light, *zone_keys, toast: nil)
    zones = LightRow.new(light: light, state: LightState.find_by(light_key: light.key)).zones.index_by(&:key)
    streams = zone_keys.map { |k|
      turbo_stream.replace("zone_#{k}", partial: "lights/zone", locals: { zone: zones[k], light_key: light.key })
    }
    streams << turbo_stream.replace("light_toast", partial: "lights/toast",
      locals: { message: toast&.dig(:message), undo: toast&.dig(:undo) }) if toast
    render turbo_stream: streams
  end
end

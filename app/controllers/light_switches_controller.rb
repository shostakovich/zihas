# app/controllers/light_switches_controller.rb
require "govee_commander"

class LightSwitchesController < ApplicationController
  def create
    light = Light.find_by(key: params[:light_key])
    return head :not_found unless light

    case params[:command]
    when "turn"
      if light.zone_lamp?
        GoveeCommander.set_zone(light, zone: "powerSwitch", on: cast_bool(params[:on]), **opts)
      else
        GoveeCommander.turn(light, on: cast_bool(params[:on]), **opts)
      end
    when "zone"
      return head :unprocessable_entity unless light.zones.include?(params[:zone])
      on = cast_bool(params[:on])
      LightState.record_zone_state(light.key, params[:zone], on)
      GoveeCommander.set_zone(light, zone: params[:zone], on: on, **opts)
      return respond_zone(light, params[:zone])
    when "brightness"
      GoveeCommander.set_brightness(light, value: params[:value].to_i, **opts)
    when "color"
      GoveeCommander.set_color(light, r: params[:r].to_i, g: params[:g].to_i, b: params[:b].to_i, **opts)
    when "color_temp"
      GoveeCommander.set_color_temp(light, kelvin: params[:temp_k].to_i, **opts)
    when "effect"
      GoveeCommander.set_effect(light, effect: params[:effect].to_s, **opts)
    when "mood"
      return head :unprocessable_entity unless apply_mood(light, params[:mood])
    else
      return head :unprocessable_entity
    end

    head :accepted
  rescue GoveeCommander::Error
    head :service_unavailable
  end

  private

  def opts = { mqtt_config: app_config.mqtt }
  def cast_bool(v) = ActiveModel::Type::Boolean.new.cast(v)

  def respond_zone(light, *zone_keys, toast: nil)
    zones = LightRow.new(light: light, state: LightState.find_by(light_key: light.key)).zones.index_by(&:key)
    streams = zone_keys.map { |k|
      turbo_stream.replace("zone_#{k}", partial: "lights/zone", locals: { zone: zones[k], light_key: light.key })
    }
    streams << turbo_stream.replace("light_toast", partial: "lights/toast",
      locals: { message: toast&.dig(:message), undo: toast&.dig(:undo) }) if toast
    render turbo_stream: streams
  end

  def apply_mood(light, id)
    mood = LightMood.find(id)
    return false unless mood

    GoveeCommander.turn(light, on: true, **opts)
    GoveeCommander.set_brightness(light, value: mood.brightness, **opts) if mood.brightness
    if mood.color_temp_k
      GoveeCommander.set_color_temp(light, kelvin: mood.color_temp_k, **opts)
    elsif mood.color
      GoveeCommander.set_color(light, r: mood.color[:r], g: mood.color[:g], b: mood.color[:b], **opts)
    end
    true
  end
end

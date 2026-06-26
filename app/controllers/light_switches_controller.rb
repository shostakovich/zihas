# app/controllers/light_switches_controller.rb
require "govee_commander"

class LightSwitchesController < ApplicationController
  def create
    light = Light.find_by(key: params[:light_key])
    return head :not_found unless light

    case params[:command]
    when "turn"
      GoveeCommander.turn(light, on: cast_bool(params[:on]), **opts)
    when "brightness"
      GoveeCommander.set_brightness(light, value: params[:value].to_i, **opts)
    when "color"
      GoveeCommander.set_color(light, r: params[:r].to_i, g: params[:g].to_i, b: params[:b].to_i, **opts)
    when "color_temp"
      GoveeCommander.set_color_temp(light, kelvin: params[:temp_k].to_i, **opts)
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
end

require "govees/commander"

class ScenesController < ApplicationController
  before_action :set_scene, only: %i[edit update destroy apply]

  def index = (@scenes = Scene.includes(scene_entries: %i[light preset]).order(:name))
  def new   = (@scene = Scene.new)
  def edit; end

  def create
    @scene = Scene.new(scene_params)
    if @scene.save
      redirect_to scenes_url, notice: "Szene angelegt."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @scene.update(scene_params)
      redirect_to scenes_url, notice: "Szene aktualisiert."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @scene.destroy
    redirect_to scenes_url, notice: "Szene gelöscht."
  end

  def apply
    @scene.scene_entries.each { |entry| apply_entry(entry) }
    redirect_to scenes_url, notice: "Szene angewendet."
  rescue Govees::Commander::Error
    redirect_to scenes_url, alert: "Bridge nicht erreichbar."
  end

  private

  def set_scene    = (@scene = Scene.find(params[:id]))
  def scene_params = params.require(:scene).permit(:name)

  def apply_entry(entry)
    light, preset = entry.light, entry.preset
    Govees::Commander.turn(light, on: preset.on, **opts)
    return unless preset.on
    Govees::Commander.set_brightness(light, value: preset.brightness, **opts) if preset.brightness
    if preset.color_temp_k && preset.color_temp_k > 0
      Govees::Commander.set_color_temp(light, kelvin: preset.color_temp_k, **opts)
    elsif preset.color_r
      Govees::Commander.set_color(light, r: preset.color_r, g: preset.color_g, b: preset.color_b, **opts)
    end
  end

  def opts = { mqtt_config: app_config.mqtt }
end

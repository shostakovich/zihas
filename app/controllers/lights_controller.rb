require "govee_commander"

class LightsController < ApplicationController
  before_action :set_light, only: %i[edit update destroy test_connection]

  def index = (@lights = Light.includes(:room).order(:name))
  def new   = (@light = Light.new)
  def edit; end

  def create
    @light = Light.new(light_params)
    if @light.save
      redirect_to lights_url, notice: "Lampe angelegt."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @light.update(light_params)
      redirect_to lights_url, notice: "Lampe aktualisiert."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @light.destroy
    redirect_to lights_url, notice: "Lampe gelöscht."
  end

  def test_connection
    GoveeCommander.refresh(@light, mqtt_config: app_config.mqtt, topic_prefix: govee_prefix)
    redirect_to lights_url, notice: "Statusabfrage gesendet — Zustand erscheint gleich."
  rescue GoveeCommander::Error
    redirect_to lights_url, alert: "Bridge nicht erreichbar."
  end

  private

  def set_light = (@light = Light.find_by!(key: params[:key]))

  def light_params
    params.require(:light).permit(:name, :room_id, :ip_address, :shelly_plug_id,
                                  :supports_color, :supports_color_temp)
  end

  def govee_prefix = (app_config.govee&.topic_prefix || "govee")
end

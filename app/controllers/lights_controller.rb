class LightsController < ApplicationController
  before_action :set_light, only: %i[show edit update destroy]

  def index = (@lights = Light.order(:name))

  def show
    @row = LightRow.new(light: @light, state: LightState.find_by(light_key: @light.key))
  end

  def edit; end

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

  private

  def set_light = (@light = Light.find_by!(key: params[:key]))

  def light_params
    params.require(:light).permit(:name, :shelly_plug_id,
                                  :supports_color, :supports_color_temp)
  end
end

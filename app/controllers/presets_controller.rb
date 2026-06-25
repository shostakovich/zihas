class PresetsController < ApplicationController
  before_action :set_preset, only: %i[edit update destroy]

  def index = (@presets = Preset.order(:name))
  def new   = (@preset = Preset.new)
  def edit; end

  def create
    @preset = Preset.new(preset_params)
    if @preset.save
      redirect_to presets_url, notice: "Preset angelegt."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @preset.update(preset_params)
      redirect_to presets_url, notice: "Preset aktualisiert."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @preset.destroy
    redirect_to presets_url, notice: "Preset gelöscht."
  end

  private

  def set_preset = (@preset = Preset.find(params[:id]))

  def preset_params
    params.require(:preset).permit(:name, :on, :brightness, :color_r, :color_g, :color_b, :color_temp_k)
  end
end

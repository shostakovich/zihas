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

  def command
    light = Light.find_by(key: params[:light_key])
    return head :not_found unless light

    operation = Lights::Operations[params[:command]]
    return head :unprocessable_entity unless operation

    result = operation.new.call(light: light, params: params, mqtt_config: app_config.mqtt)
    return render_result(light, result.value!) if result.success?

    failure = result.failure
    if failure.is_a?(Array) && failure.first == :commander
      head :service_unavailable
    else
      head :unprocessable_entity
    end
  end

  private

  def set_light = (@light = Light.find_by!(key: params[:key]))

  def light_params
    params.require(:light).permit(:name, :shelly_plug_id,
                                  :supports_color, :supports_color_temp)
  end

  def render_result(light, result)
    case result
    when Lights::Results::Power     then respond_power(light)
    when Lights::Results::Zones     then respond_zones(light, result.zone_keys, result.toast)
    when Lights::Results::NoContent then head :no_content
    else raise ArgumentError, "unhandled command result #{result.class}"
    end
  end

  # Render both targets: the detail page hero (#light_power) and the /switches
  # list card (#light_card_<key>). Turbo applies only the action whose target
  # exists in the current DOM, so one endpoint serves both pages without JS.
  def respond_power(light)
    row = LightRow.new(light: light, state: LightState.find_by(light_key: light.key))
    render turbo_stream: [
      turbo_stream.replace("light_power", partial: "lights/power", locals: { light: light, row: row }),
      turbo_stream.replace("light_card_#{light.key}", partial: "switches/light_card", locals: { row: row })
    ]
  end

  def respond_zones(light, zone_keys, toast)
    zones = LightRow.new(light: light, state: LightState.find_by(light_key: light.key)).zones.index_by(&:key)
    streams = zone_keys.map { |k|
      turbo_stream.replace("zone_#{k}", partial: "lights/zone", locals: { zone: zones[k], light_key: light.key })
    }
    streams << toast_stream(light, toast) if toast
    render turbo_stream: streams
  end

  def toast_stream(light, toast)
    message, undo =
      if toast == :clear
        [ nil, nil ]
      else
        label = Light::ZONE_META.dig(toast[:evicted], :label)
        [ "#{label} ausgeschaltet · max. #{light.max_active_zones} Zonen",
          { light_key: light.key, victim: toast[:evicted], added: toast[:added] } ]
      end
    turbo_stream.replace("light_toast", partial: "lights/toast", locals: { message: message, undo: undo })
  end
end

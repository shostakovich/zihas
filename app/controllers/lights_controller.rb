class LightsController < ApplicationController
  before_action :set_light, only: %i[show edit update]

  def show
    @snapshot = LightSnapshot.new(light: @light, state: LightState.find_by(light_key: @light.key))
  end

  def edit
    @plugs = app_config.plugs
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.update(
          "light_settings",
          partial: "lights/settings_sheet", locals: { light: @light, plugs: @plugs }
        )
      end
      format.html # edit.html.erb (Fallback ohne Turbo)
    end
  end

  def update
    if @light.update(light_params)
      redirect_to light_path(@light.key), notice: "Lampe aktualisiert."
    else
      @plugs = app_config.plugs
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.update(
            "light_settings",
            partial: "lights/settings_sheet", locals: { light: @light, plugs: @plugs }
          ), status: :unprocessable_entity
        end
        format.html { render :edit, status: :unprocessable_entity }
      end
    end
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
    params.require(:light).permit(:name, :shelly_plug_id)
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
    snapshot = LightSnapshot.new(light: light, state: LightState.find_by(light_key: light.key))
    render turbo_stream: [
      turbo_stream.replace("light_power", render_component(Lights::PowerComponent.new(snapshot: snapshot))),
      turbo_stream.replace("light_card_#{light.key}", render_component(Lights::LightCardComponent.new(snapshot: snapshot)))
    ]
  end

  # Renders a ViewComponent to an html_safe string for embedding in a Turbo Stream.
  # Version-proof vs. passing the component instance directly to turbo_stream.
  def render_component(component) = view_context.render(component)

  def respond_zones(light, zone_keys, toast)
    zones = LightSnapshot.new(light: light, state: LightState.find_by(light_key: light.key)).zones.index_by(&:key)
    streams = zone_keys.map { |k|
      turbo_stream.replace("zone_#{k}", render_component(Lights::ZoneComponent.new(zone: zones[k], light_key: light.key)))
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
    turbo_stream.replace("light_toast", render_component(Lights::ToastComponent.new(message: message, undo: undo)))
  end
end

class SwitchWindowsController < ApplicationController
  before_action :set_plug, except: :destroy

  def new
    window = SwitchWindow.new(plug_id: @plug.id, days: [])
    render turbo_stream: turbo_stream.update(
      "sw_editor_#{@plug.id}",
      partial: "switches/window_form", locals: { plug: @plug, window: window }
    )
  end

  def create
    window = SwitchWindow.new(window_params.merge(plug_id: @plug.id))
    if window.save
      render_windows
    else
      render turbo_stream: turbo_stream.update(
        "sw_editor_#{@plug.id}",
        partial: "switches/window_form", locals: { plug: @plug, window: window }
      ), status: :unprocessable_entity
    end
  end

  def edit
    window = SwitchWindow.where(plug_id: @plug.id).find(params[:id])
    render turbo_stream: turbo_stream.replace(
      helpers.dom_id(window),
      partial: "switches/window_form", locals: { plug: @plug, window: window }
    )
  end

  def update
    window = SwitchWindow.where(plug_id: @plug.id).find(params[:id])
    if window.update(window_params)
      render_windows
    else
      render turbo_stream: turbo_stream.replace(
        helpers.dom_id(window),
        partial: "switches/window_form", locals: { plug: @plug, window: window }
      ), status: :unprocessable_entity
    end
  end

  def destroy
    window = SwitchWindow.find(params[:id])
    window.destroy!
    plug = find_plug
    if plug&.switchable
      @plug = plug
      render_windows
    else
      render turbo_stream: turbo_stream.remove("orphan_window_#{window.id}")
    end
  end

  private

  def set_plug
    @plug = find_plug
    return head :not_found unless @plug
    head :unprocessable_entity unless @plug.switchable
  end

  def find_plug
    app_config.plugs.find { |p| p.id == params[:plug_id] }
  end

  def window_params
    params.require(:switch_window).permit(:on_at_time, :off_at_time, :enabled, days: [])
  end

  # Re-render windows AND head: the next-edge in the status line may have changed.
  def render_windows
    row = SwitchRow.build(@plug)
    render turbo_stream: [
      turbo_stream.replace("sw_windows_#{@plug.id}",
                           partial: "switches/windows",
                           locals: { plug: @plug, windows: row.windows }),
      turbo_stream.replace("sw_head_#{@plug.id}",
                           partial: "switches/head", locals: { row: row })
    ]
  end
end

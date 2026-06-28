class SwitchesController < ApplicationController
  def index
    plugs    = app_config.plugs.select(&:switchable)
    @rows    = SwitchRow.build_all(plugs)
    @orphaned_windows = SwitchWindow.where.not(plug_id: plugs.map(&:id)).order(:plug_id, :on_at)
    @light_snapshots = LightSnapshot.build_all(Light.order(:name))
  end
end

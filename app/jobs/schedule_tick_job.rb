require "config_loader"

class ScheduleTickJob < ApplicationJob
  queue_as :default

  def perform
    config    = load_config
    now       = Time.current
    watermark = SchedulerState.last_tick_at

    # First run ever: set the watermark and stop — no unbounded replay.
    return SchedulerState.advance!(now) if watermark.nil?

    plugs   = config.plugs.select(&:switchable).index_by(&:id)
    windows = SwitchWindow.enabled.where(plug_id: plugs.keys)
    edges   = SwitchEdgeCalculator.new(windows: windows)
                                  .latest_edge_per_plug(watermark, now)
    edges   = edges.reject { |edge| SwitchCommand.manual_after?(edge.plug_id, edge.at) }

    failed = false
    edges.each do |edge|
      PlugCommander.switch(plugs.fetch(edge.plug_id), edge.action,
                           source: :schedule, mqtt_config: config.mqtt)
    rescue PlugCommander::Error => e
      failed = true
      Rails.logger.warn("ScheduleTick: #{edge.plug_id} #{edge.action} failed: #{e.message}")
    end

    # Advance watermark only after all commands dispatched successfully.
    # If anything fails (including a crash beyond our rescue scope), the
    # watermark stays put so the next tick retries these edges.
    SchedulerState.advance!(now) unless failed
  end

  private

  def load_config
    ConfigLoader.app_config
  end
end

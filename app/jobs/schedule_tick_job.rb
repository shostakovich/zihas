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

    # Keep the watermark so the next tick retries; repeated on/off is idempotent.
    SchedulerState.advance!(now) unless failed
  end

  private

  def load_config
    path = Rails.root.join("config", Rails.env.test? ? "ziwoas.test.yml" : "ziwoas.yml").to_s
    ConfigLoader.load(path)
  end
end

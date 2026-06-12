# Per-plug view model for the "Schalten" tab.
class SwitchRow
  OFFLINE_AFTER = 5.minutes
  LOOKAHEAD     = 7.days

  attr_reader :plug, :windows, :state, :last_command, :next_edge, :last_seen_at, :watt, :now

  def self.build_all(plugs, now: Time.current)
    plug_ids = plugs.map(&:id)

    windows_by_plug = SwitchWindow.where(plug_id: plug_ids)
                                  .order(:on_at, :id).group_by(&:plug_id)
    states_by_plug  = PlugState.where(plug_id: plug_ids).index_by(&:plug_id)
    commands_by_plug = SwitchCommand
      .where(plug_id: plug_ids)
      .where("(plug_id, created_at) IN (SELECT plug_id, MAX(created_at) FROM switch_commands WHERE plug_id IN (?) GROUP BY plug_id)", plug_ids)
      .order(:created_at, :id)
      .index_by(&:plug_id)
    samples_by_plug = Sample
      .where(plug_id: plug_ids)
      .where("(plug_id, ts) IN (SELECT plug_id, MAX(ts) FROM samples WHERE plug_id IN (?) GROUP BY plug_id)", plug_ids)
      .index_by(&:plug_id)

    plugs.map do |plug|
      windows     = windows_by_plug[plug.id] || []
      last_sample = samples_by_plug[plug.id]
      new(
        plug:         plug,
        windows:      windows,
        state:        states_by_plug[plug.id],
        last_command: commands_by_plug[plug.id],
        next_edge:    SwitchEdgeCalculator.new(windows: windows.select(&:enabled))
                                          .edges_between(now, now + LOOKAHEAD).first,
        last_seen_at: last_sample && Time.zone.at(last_sample.ts),
        watt:         last_sample&.apower_w,
        now:          now,
      )
    end
  end

  def self.build(plug, now: Time.current)
    build_all([ plug ], now: now).first
  end

  def initialize(plug:, windows:, state:, last_command:, next_edge:, last_seen_at:, watt:, now: Time.current)
    @plug         = plug
    @windows      = windows
    @state        = state
    @last_command = last_command
    @next_edge    = next_edge
    @last_seen_at = last_seen_at
    @watt         = watt
    @now          = now
  end

  # The fresher signal wins: a command newer than the last confirmed device
  # state shows optimistically until the Shelly status message catches up.
  def on?
    if last_command && (state.nil? || state.updated_at.nil? || last_command.created_at >= state.updated_at)
      return last_command.action == "on"
    end
    return state.output if state
    false
  end

  def offline?
    last_seen_at.nil? || last_seen_at < now - OFFLINE_AFTER
  end

  def schedule?
    windows.any?(&:enabled)
  end
end

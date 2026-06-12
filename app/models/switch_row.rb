# Per-plug view model for the "Schalten" tab.
class SwitchRow
  OFFLINE_AFTER = 5.minutes
  LOOKAHEAD     = 7.days

  attr_reader :plug, :windows, :state, :last_command, :next_edge, :last_seen_at, :watt, :now

  def self.build_all(plugs, now: Time.current)
    plugs.map { |plug| build(plug, now: now) }
  end

  def self.build(plug, now: Time.current)
    windows     = SwitchWindow.where(plug_id: plug.id).order(:on_at, :id).to_a
    last_sample = Sample.where(plug_id: plug.id).order(ts: :desc).first
    next_edge   = SwitchEdgeCalculator.new(windows: windows.select(&:enabled))
                                      .edges_between(now, now + LOOKAHEAD).first
    new(
      plug:         plug,
      windows:      windows,
      state:        PlugState.find_by(plug_id: plug.id),
      last_command: SwitchCommand.latest_for(plug.id),
      next_edge:    next_edge,
      last_seen_at: last_sample && Time.zone.at(last_sample.ts),
      watt:         last_sample&.apower_w,
      now:          now,
    )
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

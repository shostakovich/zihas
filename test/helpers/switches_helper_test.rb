require "test_helper"

class SwitchesHelperTest < ActionView::TestCase
  include SwitchesHelper

  def row(on: true, offline: false, last_command: nil, next_edge: nil, windows: [], last_seen_at: nil)
    now = Time.zone.local(2026, 6, 15, 19, 0)
    seen = offline ? last_seen_at : now - 1.minute
    SwitchRow.new(
      plug: nil, windows: windows,
      state: PlugState.new(plug_id: "x", output: on, updated_at: now),
      last_command: last_command, next_edge: next_edge,
      last_seen_at: seen, watt: nil, now: now
    )
  end

  def edge(action, hour, min)
    SwitchEdgeCalculator::Edge.new(plug_id: "x", action: action,
                                   at: Time.zone.local(2026, 6, 15, hour, min))
  end

  test "weekday_label formats ranges, singles and full week" do
    assert_equal "Mo–Fr", weekday_label([ 1, 2, 3, 4, 5 ])
    assert_equal "Sa–So", weekday_label([ 6, 7 ])
    assert_equal "Mo, Mi, Fr", weekday_label([ 1, 3, 5 ])
    assert_equal "Mo–Mi, Fr", weekday_label([ 1, 2, 3, 5 ])
    assert_equal "täglich", weekday_label([ 1, 2, 3, 4, 5, 6, 7 ])
    assert_equal "Do", weekday_label([ 4 ])
  end

  test "window_label combines weekdays and times" do
    w = SwitchWindow.new(plug_id: "x", on_at: 1080, off_at: 1380, days: [ 1, 2, 3, 4, 5 ])
    assert_equal "Mo–Fr · 18:00–23:00", window_label(w)
  end

  test "status line shows state with source and time when command matches" do
    cmd = SwitchCommand.new(plug_id: "x", action: "on", source: "schedule",
                            created_at: Time.zone.local(2026, 6, 15, 18, 0))
    line = switch_status_line(row(on: true, last_command: cmd, next_edge: edge(:off, 23, 0),
                                  windows: [ SwitchWindow.new(enabled: true) ]))
    assert_equal "an seit 18:00 (Zeitplan) · nächste Schaltung: 23:00 → aus", line
  end

  test "status line shows bare state when command mismatches, and kein Zeitplan" do
    cmd = SwitchCommand.new(plug_id: "x", action: "on", source: "manual",
                            created_at: Time.zone.local(2026, 6, 15, 18, 0))
    assert_equal "aus · kein Zeitplan", switch_status_line(row(on: false, last_command: cmd))
  end

  test "status line for offline plug shows minutes since last message" do
    line = switch_status_line(row(offline: true, last_seen_at: Time.zone.local(2026, 6, 15, 18, 35)))
    assert_equal "keine Statusmeldung seit 25 min", line
    assert_equal "noch keine Statusmeldung", switch_status_line(row(offline: true))
  end
end

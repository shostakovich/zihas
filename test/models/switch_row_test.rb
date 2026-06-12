require "test_helper"
require "config_loader"

class SwitchRowTest < ActiveSupport::TestCase
  setup do
    Sample.delete_all
    PlugState.delete_all
    SwitchCommand.delete_all
    SwitchWindow.delete_all
    @plug = ConfigLoader::PlugCfg.new(id: "fridge", name: "Kühlschrank", role: :consumer,
                                      driver: :shelly, ain: nil, switchable: true)
  end

  test "build collects state, last command, windows, watt and next edge" do
    travel_to Time.zone.local(2026, 6, 15, 17, 0) do  # Monday
      PlugState.record_output("fridge", true)
      SwitchCommand.create!(plug_id: "fridge", action: "on", source: "schedule")
      SwitchWindow.create!(plug_id: "fridge", on_at: 1080, off_at: 1380, days: [ 1 ])
      Sample.create!(plug_id: "fridge", ts: Time.current.to_i - 30, apower_w: 42.0, aenergy_wh: 1.0)

      row = SwitchRow.build(@plug)
      assert row.on?
      refute row.offline?
      assert_in_delta 42.0, row.watt
      assert_equal 1, row.windows.size
      assert_equal :on, row.next_edge.action
      assert_equal Time.zone.local(2026, 6, 15, 18, 0), row.next_edge.at
      assert_equal "on", row.last_command.action
    end
  end

  test "offline when last sample is older than 5 minutes or missing" do
    travel_to Time.zone.local(2026, 6, 15, 17, 0) do
      assert SwitchRow.build(@plug).offline?
      Sample.create!(plug_id: "fridge", ts: 6.minutes.ago.to_i, apower_w: 1.0, aenergy_wh: 1.0)
      assert SwitchRow.build(@plug).offline?
      Sample.create!(plug_id: "fridge", ts: 4.minutes.ago.to_i, apower_w: 1.0, aenergy_wh: 1.0)
      refute SwitchRow.build(@plug).offline?
    end
  end

  test "on? falls back to last command without plug state, default off" do
    refute SwitchRow.build(@plug).on?
    SwitchCommand.create!(plug_id: "fridge", action: "on", source: "manual")
    assert SwitchRow.build(@plug).on?
  end

  test "on? lets a manual command fresher than the plug state win" do
    travel_to Time.zone.local(2026, 6, 15, 17, 0) do
      PlugState.record_output("fridge", false)
    end
    travel_to Time.zone.local(2026, 6, 15, 17, 5) do
      SwitchCommand.create!(plug_id: "fridge", action: "on", source: "manual")
      assert SwitchRow.build(@plug).on?
    end
    # Device confirms afterwards: plug state is fresher again and wins.
    travel_to Time.zone.local(2026, 6, 15, 17, 6) do
      PlugState.find_by(plug_id: "fridge").touch
      refute SwitchRow.build(@plug).on?
    end
  end

  test "disabled windows do not produce a next edge" do
    travel_to Time.zone.local(2026, 6, 15, 17, 0) do
      SwitchWindow.create!(plug_id: "fridge", on_at: 1080, off_at: 1380, days: [ 1 ], enabled: false)
      row = SwitchRow.build(@plug)
      assert_nil row.next_edge
      refute row.schedule?
      assert_equal 1, row.windows.size  # still listed for editing
    end
  end

  test "build_all returns same rows as individual build" do
    plugs = [ plug_struct("a"), plug_struct("b") ]
    all   = SwitchRow.build_all(plugs, now: @now)
    singles = plugs.map { |p| SwitchRow.build(p, now: @now) }
    assert_equal singles.map(&:on?),       all.map(&:on?)
    assert_equal singles.map(&:offline?),  all.map(&:offline?)
    assert_equal singles.map { |r| r.windows.map(&:id) }, all.map { |r| r.windows.map(&:id) }
  end
end

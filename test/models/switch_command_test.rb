require "test_helper"

class SwitchCommandTest < ActiveSupport::TestCase
  setup { SwitchCommand.delete_all }

  test "validates action and source" do
    refute SwitchCommand.new(plug_id: "x", action: "toggle", source: "manual").valid?
    refute SwitchCommand.new(plug_id: "x", action: "on", source: "api").valid?
    assert SwitchCommand.new(plug_id: "x", action: "on", source: "schedule").valid?
  end

  test "latest_for returns newest command for plug" do
    SwitchCommand.create!(plug_id: "a", action: "on",  source: "manual",   created_at: 2.hours.ago)
    SwitchCommand.create!(plug_id: "a", action: "off", source: "schedule", created_at: 1.hour.ago)
    SwitchCommand.create!(plug_id: "b", action: "on",  source: "manual",   created_at: 1.minute.ago)
    assert_equal "off", SwitchCommand.latest_for("a").action
    assert_nil SwitchCommand.latest_for("missing")
  end

  test "manual_after? only counts manual commands after the given time" do
    SwitchCommand.create!(plug_id: "a", action: "on", source: "schedule", created_at: 1.minute.ago)
    refute SwitchCommand.manual_after?("a", 5.minutes.ago)
    SwitchCommand.create!(plug_id: "a", action: "off", source: "manual", created_at: 1.minute.ago)
    assert SwitchCommand.manual_after?("a", 5.minutes.ago)
    refute SwitchCommand.manual_after?("a", Time.current)
  end
end

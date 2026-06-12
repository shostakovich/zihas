require "test_helper"

class SwitchWindowTest < ActiveSupport::TestCase
  def valid_attrs
    { plug_id: "fridge", on_at: 1080, off_at: 1380, days: [ 1, 2, 3, 4, 5 ] }
  end

  test "valid window saves" do
    assert SwitchWindow.new(valid_attrs).valid?
  end

  test "enabled defaults to true" do
    assert SwitchWindow.create!(valid_attrs).enabled
  end

  test "on_at and off_at must be within 0..1439" do
    refute SwitchWindow.new(valid_attrs.merge(on_at: -1)).valid?
    refute SwitchWindow.new(valid_attrs.merge(off_at: 1440)).valid?
  end

  test "on_at must differ from off_at" do
    refute SwitchWindow.new(valid_attrs.merge(on_at: 600, off_at: 600)).valid?
  end

  test "days must be a non-empty list of ISO weekdays" do
    refute SwitchWindow.new(valid_attrs.merge(days: [])).valid?
    refute SwitchWindow.new(valid_attrs.merge(days: [ 0 ])).valid?
    refute SwitchWindow.new(valid_attrs.merge(days: [ 8 ])).valid?
  end

  test "days are normalized to sorted unique integers, blanks dropped" do
    w = SwitchWindow.create!(valid_attrs.merge(days: [ "", "5", "1", "5" ]))
    assert_equal [ 1, 5 ], w.days
  end

  test "crosses_midnight? when on_at > off_at" do
    assert SwitchWindow.new(valid_attrs.merge(on_at: 1320, off_at: 360)).crosses_midnight?
    refute SwitchWindow.new(valid_attrs).crosses_midnight?
  end

  test "on_at_time and off_at_time format and parse HH:MM" do
    w = SwitchWindow.new(valid_attrs)
    assert_equal "18:00", w.on_at_time
    assert_equal "23:00", w.off_at_time
    w.on_at_time = "07:05"
    assert_equal 425, w.on_at
    w.off_at_time = ""
    assert_nil w.off_at
    w.on_at_time = "18:00:00"
    assert_equal 1080, w.on_at
    w.on_at_time = "24:00"
    assert_nil w.on_at
    w.on_at_time = "23:60"
    assert_nil w.on_at
  end

  test "enabled scope" do
    SwitchWindow.delete_all
    SwitchWindow.create!(valid_attrs)
    SwitchWindow.create!(valid_attrs.merge(enabled: false))
    assert_equal 1, SwitchWindow.enabled.count
  end
end

require "test_helper"

class PlugStateTest < ActiveSupport::TestCase
  setup { PlugState.delete_all }

  test "record_output creates a row and returns true" do
    assert PlugState.record_output("fridge", true)
    assert_equal true, PlugState.find_by(plug_id: "fridge").output
  end

  test "record_output with unchanged output writes nothing and returns false" do
    travel_to Time.zone.local(2026, 6, 15, 12, 0) do
      PlugState.record_output("fridge", true)
    end
    travel_to Time.zone.local(2026, 6, 15, 12, 5) do
      refute PlugState.record_output("fridge", true)
    end
    assert_equal Time.zone.local(2026, 6, 15, 12, 0), PlugState.find_by(plug_id: "fridge").updated_at
  end

  test "record_output updates on change" do
    PlugState.record_output("fridge", true)
    assert PlugState.record_output("fridge", false)
    assert_equal false, PlugState.find_by(plug_id: "fridge").output
    assert_equal 1, PlugState.count
  end
end

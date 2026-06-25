# test/models/light_state_test.rb
require "test_helper"

class LightStateTest < ActiveSupport::TestCase
  setup { LightState.delete_all }

  test "record_state creates a row and returns true" do
    assert LightState.record_state("lamp", on: true, brightness: 50)
    state = LightState.find_by(light_key: "lamp")
    assert_equal true, state.on
    assert_equal 50,   state.brightness
  end

  test "record_state returns false when visible fields are unchanged" do
    LightState.record_state("lamp", on: true, brightness: 50)
    refute LightState.record_state("lamp", on: true, brightness: 50)
  end

  test "record_state returns true and updates on a visible change" do
    LightState.record_state("lamp", on: true, brightness: 50)
    assert LightState.record_state("lamp", on: true, brightness: 80)
    assert_equal 80, LightState.find_by(light_key: "lamp").brightness
    assert_equal 1,  LightState.count
  end

  test "record_state updates last_seen_at even without a visible change" do
    travel_to Time.zone.local(2026, 6, 24, 12, 0) do
      LightState.record_state("lamp", on: true, last_seen_at: Time.current)
    end
    travel_to Time.zone.local(2026, 6, 24, 12, 5) do
      refute LightState.record_state("lamp", on: true, last_seen_at: Time.current)
    end
    assert_equal Time.zone.local(2026, 6, 24, 12, 5),
                 LightState.find_by(light_key: "lamp").last_seen_at
  end
end

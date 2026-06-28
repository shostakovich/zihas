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

  test "zone_states defaults to an empty hash" do
    assert_equal({}, LightState.new.zone_states)
  end

  test "record_zone_state upserts a single zone bit and reports change" do
    assert LightState.record_zone_state("UP1", "rippleLightToggle", true)
    state = LightState.find_by(light_key: "UP1")
    assert_equal({ "rippleLightToggle" => true }, state.zone_states)

    refute LightState.record_zone_state("UP1", "rippleLightToggle", true), "no change on identical write"
    assert LightState.record_zone_state("UP1", "rippleLightToggle", false), "change on flip"
    assert_equal({ "rippleLightToggle" => false }, LightState.find_by(light_key: "UP1").zone_states)
  end

  test "record_zone_state preserves other zones" do
    LightState.record_zone_state("UP1", "bottomLightToggle", true)
    LightState.record_zone_state("UP1", "sideLightToggle", true)
    assert_equal({ "bottomLightToggle" => true, "sideLightToggle" => true },
                 LightState.find_by(light_key: "UP1").zone_states)
  end

  test "concurrent zone writes do not lose updates" do
    LightState.create!(light_key: "K", zone_states: {})
    # zwei echte Threads mit eigener DB-Verbindung; ohne Lock geht ein Bit verloren
    threads = [
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { LightState.record_zone_state("K", "rippleLightToggle", true) } },
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { LightState.record_zone_state("K", "sideLightToggle", true) } }
    ]
    threads.each(&:join)
    bits = LightState.find_by(light_key: "K").zone_states
    assert_equal true, bits["rippleLightToggle"]
    assert_equal true, bits["sideLightToggle"]
  end

  test "for_lights indexes states by light_key" do
    LightState.record_state("A1B2C3D4E5F60010", on: true)
    LightState.record_state("A1B2C3D4E5F60011", on: false)

    states = LightState.for_lights(%w[A1B2C3D4E5F60010 A1B2C3D4E5F60011])
    assert_equal %w[A1B2C3D4E5F60010 A1B2C3D4E5F60011], states.keys.sort
    assert_equal true, states["A1B2C3D4E5F60010"].on
  end
end

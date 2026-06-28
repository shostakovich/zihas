# test/models/lights/operations/zone_operations_test.rb
require "test_helper"

class Lights::Operations::ZoneOperationsTest < ActiveSupport::TestCase
  setup { @cfg = Object.new }

  test "SetZone toggles a valid zone and returns it without a toast" do
    light = Light.create!(name: "U", key: "Z0", zones: %w[bottomLightToggle rippleLightToggle])
    calls = []
    Govees::Commander.stub(:set_zone, ->(l, zone:, on:, mqtt_config:) { calls << [ zone, on ] }) do
      result = Lights::Operations::SetZone.new.call(light: light, params: { zone: "rippleLightToggle", on: "true" }, mqtt_config: @cfg)
      assert result.success?
      r = result.value!
      assert_equal [ "rippleLightToggle" ], r.zone_keys
      assert_nil r.toast
    end
    assert_equal [ [ "rippleLightToggle", true ] ], calls
    assert_equal true, LightState.find_by(light_key: "Z0").zone_states["rippleLightToggle"]
  end

  test "SetZone rejects a zone not on this light" do
    light = Light.create!(name: "U", key: "Z2", zones: %w[bottomLightToggle])
    result = Lights::Operations::SetZone.new.call(light: light, params: { zone: "powerSwitch", on: "true" }, mqtt_config: @cfg)
    assert result.failure?
    assert_equal :invalid, result.failure.first
  end

  test "SetZone evicts an on side when over the limit and emits a toast" do
    light = Light.create!(name: "U", key: "Z1", sku: "H60B0",
                          zones: %w[bottomLightToggle rippleLightToggle sideLightToggle])
    LightState.record_zone_state("Z1", "bottomLightToggle", true) # main on
    LightState.record_zone_state("Z1", "rippleLightToggle", true) # one side on -> at limit (2)
    calls = []
    Govees::Commander.stub(:set_zone, ->(l, zone:, on:, mqtt_config:) { calls << [ zone, on ] }) do
      result = Lights::Operations::SetZone.new.call(light: light, params: { zone: "sideLightToggle", on: "true" }, mqtt_config: @cfg)
      assert result.success?
      r = result.value!
      assert_equal [ "sideLightToggle", "rippleLightToggle" ], r.zone_keys
      assert_equal({ evicted: "rippleLightToggle", added: "sideLightToggle" }, r.toast)
    end
    state = LightState.find_by(light_key: "Z1")
    assert_equal false, state.zone_states["rippleLightToggle"]
    assert_equal true,  state.zone_states["sideLightToggle"]
    assert_equal true,  state.zone_states["bottomLightToggle"]
    assert_includes calls, [ "rippleLightToggle", false ]
    assert_includes calls, [ "sideLightToggle", true ]
  end

  test "SetZone does not touch the DB when the commander fails" do
    light = Light.create!(key: "K", name: "L", sku: "H60B0", zones: %w[rippleLightToggle sideLightToggle])
    LightState.create!(light_key: "K", zone_states: {})

    Govees::Commander.stub :set_zone, ->(*, **) { raise Govees::Commander::Error, "broker down" } do
      result = Lights::Operations::SetZone.new.call(light: light, params: { zone: "rippleLightToggle", on: "true" }, mqtt_config: nil)
      assert result.failure?
    end

    assert_equal({}, LightState.find_by(light_key: "K").zone_states,
                 "Bei Commander-Fehler darf der DB-Zustand nicht verändert sein")
  end

  test "UndoZone restores victim, turns off added, clears the toast" do
    light = Light.create!(name: "U", key: "Z3", zones: %w[rippleLightToggle sideLightToggle])
    LightState.record_zone_state("Z3", "sideLightToggle", true)
    calls = []
    Govees::Commander.stub(:set_zone, ->(l, zone:, on:, mqtt_config:) { calls << [ zone, on ] }) do
      result = Lights::Operations::UndoZone.new.call(light: light, params: { victim: "rippleLightToggle", added: "sideLightToggle" }, mqtt_config: @cfg)
      assert result.success?
      r = result.value!
      assert_equal [ "rippleLightToggle", "sideLightToggle" ], r.zone_keys
      assert_equal :clear, r.toast
    end
    state = LightState.find_by(light_key: "Z3")
    assert_equal true,  state.zone_states["rippleLightToggle"]
    assert_equal false, state.zone_states["sideLightToggle"]
    assert_includes calls, [ "rippleLightToggle", true ]
    assert_includes calls, [ "sideLightToggle", false ]
  end
end

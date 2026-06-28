# test/models/lights/operations/turn_test.rb
require "test_helper"

class Lights::Operations::TurnTest < ActiveSupport::TestCase
  setup { @cfg = Object.new }

  test "simple lamp calls Commander.turn, persists state, returns Power" do
    light = Light.create!(name: "L", key: "S1", zones: [])
    calls = []
    Govees::Commander.stub(:turn, ->(l, on:, mqtt_config:) { calls << [ l.key, on ] }) do
      result = Lights::Operations::Turn.new.call(light: light, params: { on: "true" }, mqtt_config: @cfg)
      assert result.success?
      assert_instance_of Lights::Results::Power, result.value!
    end
    assert_equal [ [ "S1", true ] ], calls
    assert_equal true, LightState.find_by(light_key: "S1").on
  end

  test "zone lamp routes power through powerSwitch" do
    light = Light.create!(name: "U", key: "U1", zones: %w[bottomLightToggle sideLightToggle])
    seen = {}
    Govees::Commander.stub(:set_zone, ->(l, zone:, on:, mqtt_config:) { seen[:zone] = zone; seen[:on] = on }) do
      Lights::Operations::Turn.new.call(light: light, params: { on: "true" }, mqtt_config: @cfg)
    end
    assert_equal "powerSwitch", seen[:zone]
    assert_equal true, seen[:on]
  end

  test "broker failure returns a commander failure" do
    light = Light.create!(name: "L", key: "S2", zones: [])
    boom = ->(*, **) { raise Govees::Commander::Error, "down" }
    Govees::Commander.stub(:turn, boom) do
      result = Lights::Operations::Turn.new.call(light: light, params: { on: "true" }, mqtt_config: @cfg)
      assert result.failure?
      assert_equal :commander, result.failure.first
    end
  end

  test "uncoercible flag returns an invalid failure" do
    light = Light.create!(name: "L", key: "S3", zones: [])
    result = Lights::Operations::Turn.new.call(light: light, params: { on: "" }, mqtt_config: @cfg)
    assert result.failure?
    assert_equal :invalid, result.failure.first
  end
end

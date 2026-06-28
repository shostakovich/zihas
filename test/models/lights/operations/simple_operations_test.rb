# test/models/lights/operations/simple_operations_test.rb
require "test_helper"

class Lights::Operations::SimpleOperationsTest < ActiveSupport::TestCase
  setup do
    @cfg   = Object.new
    @light = Light.create!(name: "L", key: "C1", zones: [])
  end

  test "SetBrightness forwards the coerced value and returns NoContent" do
    seen = nil
    Govees::Commander.stub(:set_brightness, ->(l, value:, mqtt_config:) { seen = value }) do
      result = Lights::Operations::SetBrightness.new.call(light: @light, params: { value: "42" }, mqtt_config: @cfg)
      assert result.success?
      assert_instance_of Lights::Results::NoContent, result.value!
    end
    assert_equal 42, seen
  end

  test "SetBrightness rejects an out-of-range value" do
    result = Lights::Operations::SetBrightness.new.call(light: @light, params: { value: "0" }, mqtt_config: @cfg)
    assert result.failure?
    assert_equal :invalid, result.failure.first
  end

  test "SetColor forwards three components" do
    seen = {}
    Govees::Commander.stub(:set_color, ->(l, r:, g:, b:, mqtt_config:) { seen = { r:, g:, b: } }) do
      result = Lights::Operations::SetColor.new.call(light: @light, params: { r: "10", g: "20", b: "30" }, mqtt_config: @cfg)
      assert result.success?
    end
    assert_equal({ r: 10, g: 20, b: 30 }, seen)
  end

  test "SetColorTemp forwards kelvin from the temp_k param" do
    seen = nil
    Govees::Commander.stub(:set_color_temp, ->(l, kelvin:, mqtt_config:) { seen = kelvin }) do
      Lights::Operations::SetColorTemp.new.call(light: @light, params: { temp_k: "4000" }, mqtt_config: @cfg)
    end
    assert_equal 4000, seen
  end

  test "SetScene accepts the effect param" do
    seen = nil
    Govees::Commander.stub(:set_scene, ->(l, scene:, mqtt_config:) { seen = scene }) do
      Lights::Operations::SetScene.new.call(light: @light, params: { effect: "Forest" }, mqtt_config: @cfg)
    end
    assert_equal "Forest", seen
  end

  test "SetScene also accepts the scene param" do
    seen = nil
    Govees::Commander.stub(:set_scene, ->(l, scene:, mqtt_config:) { seen = scene }) do
      Lights::Operations::SetScene.new.call(light: @light, params: { scene: "Ocean" }, mqtt_config: @cfg)
    end
    assert_equal "Ocean", seen
  end

  test "broker failure surfaces as a commander failure" do
    boom = ->(*, **) { raise Govees::Commander::Error, "down" }
    Govees::Commander.stub(:set_brightness, boom) do
      result = Lights::Operations::SetBrightness.new.call(light: @light, params: { value: "42" }, mqtt_config: @cfg)
      assert result.failure?
      assert_equal :commander, result.failure.first
    end
  end
end

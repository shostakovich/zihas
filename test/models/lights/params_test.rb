# test/models/lights/params_test.rb
require "test_helper"

class Lights::ParamsTest < ActiveSupport::TestCase
  test "Turn coerces the on flag" do
    assert_equal true,  Lights::Params::Turn.new(on: "true").on
    assert_equal false, Lights::Params::Turn.new(on: "false").on
  end

  test "Brightness wraps out-of-range in Dry::Struct::Error" do
    assert_equal 42, Lights::Params::Brightness.new(value: "42").value
    assert_raises(Dry::Struct::Error) { Lights::Params::Brightness.new(value: "0") }
  end

  test "Color coerces three components" do
    c = Lights::Params::Color.new(r: "10", g: "20", b: "30")
    assert_equal [ 10, 20, 30 ], [ c.r, c.g, c.b ]
  end

  test "ColorTemp coerces kelvin" do
    assert_equal 4000, Lights::Params::ColorTemp.new(kelvin: "4000").kelvin
  end

  test "Scene rejects a blank name" do
    assert_equal "Forest", Lights::Params::Scene.new(scene: "Forest").scene
    assert_raises(Dry::Struct::Error) { Lights::Params::Scene.new(scene: "") }
  end
end

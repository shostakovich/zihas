# test/models/lights/results_test.rb
require "test_helper"

class Lights::ResultsTest < ActiveSupport::TestCase
  test "Power carries the light" do
    light = Light.new(key: "A")
    assert_same light, Lights::Results::Power.new(light: light).light
  end

  test "Zones carries keys and toast payload" do
    r = Lights::Results::Zones.new(light: Light.new(key: "A"),
                                   zone_keys: %w[sideLightToggle rippleLightToggle],
                                   toast: { evicted: "rippleLightToggle", added: "sideLightToggle" })
    assert_equal %w[sideLightToggle rippleLightToggle], r.zone_keys
    assert_equal({ evicted: "rippleLightToggle", added: "sideLightToggle" }, r.toast)
  end

  test "NoContent constructs" do
    assert_instance_of Lights::Results::NoContent, Lights::Results::NoContent.new
  end
end

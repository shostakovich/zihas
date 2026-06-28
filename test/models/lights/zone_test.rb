require "test_helper"

class Lights::ZoneTest < ActiveSupport::TestCase
  test "exposes typed key/label/role/on" do
    zone = Lights::Zone.new(key: "bottomLightToggle", label: "Leselicht", role: "main", on: true)
    assert_equal "bottomLightToggle", zone.key
    assert_equal "Leselicht", zone.label
    assert_equal "main", zone.role
    assert_equal true, zone.on
  end

  test "coerces on to a boolean" do
    zone = Lights::Zone.new(key: "k", label: "L", role: "side", on: "false")
    assert_equal false, zone.on
  end
end

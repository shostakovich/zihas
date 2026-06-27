# test/models/lights/contracts_test.rb
require "test_helper"

class Lights::ContractsTest < ActiveSupport::TestCase
  setup do
    @light = Light.new(name: "Up", key: "X", zones: %w[rippleLightToggle sideLightToggle])
  end

  test "Zone passes for a known zone and coerces on" do
    r = Lights::Contracts::Zone.new(light: @light).call(zone: "rippleLightToggle", on: "true")
    assert r.success?
    assert_equal({ zone: "rippleLightToggle", on: true }, r.to_h)
  end

  test "Zone fails for a zone not on this light" do
    r = Lights::Contracts::Zone.new(light: @light).call(zone: "powerSwitch", on: "true")
    assert r.failure?
  end

  test "ZoneUndo requires both zones on the light" do
    ok = Lights::Contracts::ZoneUndo.new(light: @light).call(victim: "rippleLightToggle", added: "sideLightToggle")
    assert ok.success?
    bad = Lights::Contracts::ZoneUndo.new(light: @light).call(victim: "rippleLightToggle", added: "nope")
    assert bad.failure?
  end
end

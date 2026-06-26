# test/models/light_row_test.rb
require "test_helper"

class LightRowTest < ActiveSupport::TestCase
  setup do
    Light.delete_all
    LightState.delete_all
  end

  test "build_all returns a row per light with its state" do
    light = Light.create!(name: "Stehlampe", key: "A1B2C3D4E5F60010")
    LightState.record_state(light.key, on: true, brightness: 70, reachable: true)

    rows = LightRow.build_all(Light.order(:name))
    assert_equal 1, rows.length
    row = rows.first
    assert_equal light, row.light
    assert_equal true,  row.on?
    assert_equal 70,    row.brightness
    assert_equal true,  row.reachable?
  end

  test "defaults are safe when no state exists" do
    Light.create!(name: "Neu", key: "A1B2C3D4E5F60011")
    row = LightRow.build_all(Light.all).first
    assert_equal false, row.on?
    assert_equal 0,     row.brightness
    assert_equal false, row.reachable?
  end
end

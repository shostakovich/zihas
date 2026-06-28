# test/models/light_snapshot_test.rb
require "test_helper"

class LightSnapshotTest < ActiveSupport::TestCase
  setup do
    Light.delete_all
    LightState.delete_all
  end

  test "build_all returns a snapshot per light with its state" do
    light = Light.create!(name: "Stehlampe", key: "A1B2C3D4E5F60010")
    LightState.record_state(light.key, on: true, brightness: 70, reachable: true)

    rows = LightSnapshot.build_all(Light.order(:name))
    assert_equal 1, rows.length
    row = rows.first
    assert_equal light, row.light
    assert_equal true,  row.on?
    assert_equal 70,    row.brightness
    assert_equal true,  row.reachable?
  end

  test "defaults are safe when no state exists" do
    Light.create!(name: "Neu", key: "A1B2C3D4E5F60011")
    row = LightSnapshot.build_all(Light.all).first
    assert_equal false, row.on?
    assert_equal 0,     row.brightness
    assert_equal false, row.reachable?
  end

  def row(attrs)
    light = Light.new(key: "K1", name: "Lampe")
    state = attrs.nil? ? nil : LightState.new(attrs.merge(light_key: "K1"))
    LightSnapshot.new(light: light, state: state)
  end

  test "white light when colour temp set" do
    r = row(on: true, brightness: 60, color_temp_k: 2700)
    assert r.white?
    assert_nil r.color_hex
  end

  test "colour light exposes hex and rgb" do
    r = row(on: true, brightness: 40, color_r: 255, color_g: 107, color_b: 61)
    refute r.white?
    assert_equal "#ff6b3d", r.color_hex
    assert_equal [ 255, 107, 61 ], r.rgb
  end

  test "no state defaults to off white" do
    r = row(nil)
    assert r.white?
  end

  test "zone_lamp? mirrors the light" do
    light = Light.new(zones: %w[bottomLightToggle sideLightToggle])
    assert LightSnapshot.new(light: light, state: nil).zone_lamp?
  end

  test "zones presents main-first with labels and on-state" do
    light = Light.new(zones: %w[rippleLightToggle bottomLightToggle sideLightToggle])
    state = LightState.new(zone_states: { "bottomLightToggle" => true, "rippleLightToggle" => false })
    rows  = LightSnapshot.new(light: light, state: state).zones
    assert_equal %w[bottomLightToggle rippleLightToggle sideLightToggle], rows.map(&:key)
    assert_equal "main", rows.first.role
    assert_equal "Leselicht", rows.first.label
    assert_equal true,  rows.first.on
    assert_equal false, rows[1].on # ripple, no state -> false
    assert_equal false, rows[2].on # side, missing -> false
  end
end

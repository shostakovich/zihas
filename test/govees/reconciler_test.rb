# test/govees/reconciler_test.rb
require "test_helper"
require "govees/reconciler"
require "govees/lan_client"
require "govees/device"

class GoveesReconcilerTest < ActiveSupport::TestCase
  def device(zones: [ "rippleLightToggle" ])
    Govees::Device.new(key: "K", api_id: "14:AB", sku: "H60B0", name: "n", ip: "1.2.3.4",
      supports_color: true, supports_color_temp: true, zones: zones,
      scenes: [], scene_index: {}, power_only: false)
  end

  test "lan_to_telemetry maps a Status struct" do
    s = Govees::LanClient::Status.new(on: true, brightness: 30, color_r: 1, color_g: 2, color_b: 3,
                                      color_temp_k: 0, sku: "H60B0")
    t = Govees::Reconciler.lan_to_telemetry(s)
    assert_equal true, t[:on]
    assert_equal 30, t[:brightness]
    assert_equal({ r: 1, g: 2, b: 3 }, t[:color])
    assert_equal true, t[:reachable]
  end

  test "api_to_telemetry maps power/brightness/colour/online and zone bits" do
    state = { "powerSwitch" => 1, "brightness" => 70, "colorTemperatureK" => 3000, "colorRgb" => 0,
              "online" => true, "rippleLightToggle" => 1 }
    t = Govees::Reconciler.api_to_telemetry(state, device)
    assert_equal true, t[:on]
    assert_equal 70, t[:brightness]
    assert_equal 3000, t[:color_temp_k]
    assert_equal true, t[:reachable]
    assert_equal({ "rippleLightToggle" => true }, t[:zone_states])
  end

  test "apply_lan that needs clarification triggers an immediate api state call" do
    store = Govees::StateStore.new(pending_window_s: 0.0, clock: -> { 100.0 })
    store.record_command("K", on: true, brightness: 50)
    api_calls = []
    api = Object.new
    api.define_singleton_method(:state) { |sku:, device:| api_calls << device; { "powerSwitch" => 1, "brightness" => 80, "online" => true } }
    dev = device
    registry = Object.new.tap { |r| r.define_singleton_method(:find) { |_| dev } ; r.define_singleton_method(:all) { [ dev ] } }
    rec = Govees::Reconciler.new(registry: registry, lan: nil, api: api, store: store, logger: Logger.new(IO::NULL))
    rec.apply_lan("K", Govees::LanClient::Status.new(on: true, brightness: 80, color_temp_k: 0))
    assert_equal [ "14:AB" ], api_calls
    assert_equal 80, store.published("K")[:brightness]
  end
end

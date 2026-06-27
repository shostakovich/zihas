# test/govees/command_router_test.rb
require "test_helper"
require "govees/command_router"
require "govees/device"

class GoveesCommandRouterTest < ActiveSupport::TestCase
  class FakeLan
    attr_reader :calls
    def initialize = @calls = []
    def turn(ip, on)          = @calls << [ :turn, ip, on ]
    def brightness(ip, v)     = @calls << [ :brightness, ip, v ]
    def color(ip, r:, g:, b:) = @calls << [ :color, ip, r, g, b ]
    def color_temp(ip, k)     = @calls << [ :color_temp, ip, k ]
    def request_status(ip)    = @calls << [ :status, ip ]
  end

  class FakeApi
    attr_reader :calls
    def initialize = @calls = []
    def control(**kw) = (@calls << kw) && true
  end

  def device(ip:, sku: "H60B0", power_only: false)
    Govees::Device.new(key: "K", api_id: "14:AB", sku: sku, name: "n", ip: ip,
      supports_color: true, supports_color_temp: true, zones: [ "rippleLightToggle" ],
      scenes: [ "Sunset" ], scene_index: { "Sunset" => { id: 5, param_id: 9 } }, power_only: power_only)
  end

  def build(dev)
    registry = Object.new.tap { |r| r.define_singleton_method(:find) { |_k| dev } }
    @lan = FakeLan.new; @api = FakeApi.new
    @store = Govees::StateStore.new(clock: -> { 0.0 })
    Govees::CommandRouter.new(registry: registry, lan: @lan, api: @api, store: @store,
                              logger: Logger.new(IO::NULL))
  end

  test "brightness on a lan-reachable lamp goes over LAN and records optimistic state" do
    router = build(device(ip: "1.2.3.4"))
    pub = router.handle("K", { "brightness" => 40 })
    assert_includes @lan.calls, [ :brightness, "1.2.3.4", 40 ]
    assert_equal 40, pub[:brightness]
  end

  test "power falls back to API powerSwitch when no LAN ip is known" do
    router = build(device(ip: nil))
    router.handle("K", { "power" => "on" })
    assert_equal "powerSwitch", @api.calls.first[:instance]
    assert_equal 1, @api.calls.first[:value]
  end

  test "zone toggle always goes over the API" do
    router = build(device(ip: "1.2.3.4"))
    router.handle("K", { "zone" => { "name" => "rippleLightToggle", "on" => true } })
    assert_equal "rippleLightToggle", @api.calls.first[:instance]
    assert_equal 1, @api.calls.first[:value]
    assert_empty @lan.calls.reject { |c| c.first == :status }
  end

  test "scene resolves name to id/paramId and controls via API lightScene" do
    router = build(device(ip: "1.2.3.4"))
    router.handle("K", { "scene" => "Sunset" })
    call = @api.calls.first
    assert_equal "lightScene", call[:instance]
    assert_equal({ "id" => 5, "paramId" => 9 }, call[:value])
  end

  test "unknown device returns nil" do
    registry = Object.new.tap { |r| r.define_singleton_method(:find) { |_k| nil } }
    router = Govees::CommandRouter.new(registry: registry, lan: FakeLan.new, api: FakeApi.new,
      store: Govees::StateStore.new(clock: -> { 0.0 }), logger: Logger.new(IO::NULL))
    assert_nil router.handle("X", { "power" => "on" })
  end

  test "zone command preserves other zone bits" do
    router = build(device(ip: "1.2.3.4"))
    @store.record_command("K", zone_states: { "sideLightToggle" => true })
    router.handle("K", { "zone" => { "name" => "rippleLightToggle", "on" => true } })
    assert_equal({ "sideLightToggle" => true, "rippleLightToggle" => true },
                 @store.published("K")[:zone_states])
  end
end

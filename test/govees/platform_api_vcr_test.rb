# test/govees/platform_api_vcr_test.rb
require "test_helper"
require "govees/platform_api"
require "govees/reconciler"
require "govees/device"

class GoveesPlatformApiVcrTest < ActiveSupport::TestCase
  RECORDING = ENV["VCR_RECORD"].present?

  def cassette_present?(name)
    File.exist?(Rails.root.join("test/vcr_cassettes", "#{name}.yml"))
  end

  setup { @api = Govees::PlatformApi.new(api_key: Govees::CassetteScrubber.api_key) }

  test "devices parses a real (anonymised) API response" do
    skip "Cassette fehlt — aufnehmen mit: VCR_RECORD=1 bin/rails test #{__FILE__} (echter govee.api_key in config/ziwoas.yml nötig)" \
      unless RECORDING || cassette_present?("govees/devices")

    devices = VCR.use_cassette("govees/devices", record: RECORDING ? :all : :none) { @api.devices }
    assert devices.is_a?(Array)
    assert devices.first.key?("sku"), "Antwort muss SKU enthalten"
  end

  test "a real state response maps through DeviceState to telemetry" do
    skip "Cassette fehlt — aufnehmen mit: VCR_RECORD=1 bin/rails test #{__FILE__} (echter govee.api_key in config/ziwoas.yml nötig)" \
      unless RECORDING || cassette_present?("govees/devices")

    sku, dev = VCR.use_cassette("govees/devices", record: RECORDING ? :all : :none) { @api.devices.first.values_at("sku", "device") }

    skip "Cassette fehlt — aufnehmen mit: VCR_RECORD=1 bin/rails test #{__FILE__} (echter govee.api_key in config/ziwoas.yml nötig)" \
      unless RECORDING || cassette_present?("govees/state")

    state = VCR.use_cassette("govees/state", record: RECORDING ? :all : :none) { @api.state(sku: sku, device: dev) }
    device = Govees::Device.new(key: "K", api_id: dev, sku: sku, name: "n", ip: nil,
      supports_color: true, supports_color_temp: true, zones: [], scenes: [], scene_index: {}, power_only: false)
    t = Govees::Reconciler.api_to_telemetry(state, device)
    assert_includes [ true, false ], t[:on]
    assert_includes [ true, false ], t[:reachable]
  end
end

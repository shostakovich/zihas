require "test_helper"
require "config_loader"

class TrmnlPushJobTest < ActiveJob::TestCase
  def build_config(trmnl_webhook_url:)
    plug_bkw    = ConfigLoader::PlugCfg.new(id: "bkw",    name: "BKW",   role: :producer, driver: :shelly, ain: nil)
    plug_fridge = ConfigLoader::PlugCfg.new(id: "fridge", name: "Fridge", role: :consumer, driver: :shelly, ain: nil)
    mqtt = ConfigLoader::MqttCfg.new(host: "localhost", port: 1883, topic_prefix: "shellies")
    ConfigLoader::Config.new(
      electricity_price_eur_per_kwh: 0.32,
      timezone: "Europe/Berlin",
      mqtt: mqtt,
      fritz_poll: nil,
      plugs: [ plug_bkw, plug_fridge ],
      fritz_box: nil,
      weather: nil,
      trmnl_webhook_url: trmnl_webhook_url,
    )
  end

  def with_config(config)
    original = ConfigLoader.method(:load)
    ConfigLoader.define_singleton_method(:load) { |_path| config }
    yield
  ensure
    ConfigLoader.define_singleton_method(:load, original)
  end

  def stub_builder(payload)
    fake = Object.new
    fake.define_singleton_method(:build) { payload }
    TrmnlPayloadBuilder.stub(:new, ->(**) { fake }) { yield }
  end

  test "does nothing when trmnl_webhook_url is not configured" do
    posted = []
    TrmnlPushJob.stub(:post_json, ->(*args) { posted << args; nil }) do
      with_config(build_config(trmnl_webhook_url: nil)) do
        TrmnlPushJob.perform_now
      end
    end
    assert_empty posted
  end

  test "POSTs the payload as JSON to the configured URL" do
    payload  = { "merge_variables" => { "ts" => 1, "pv_kwh" => 0 } }
    captured = nil
    stub_builder(payload) do
      TrmnlPushJob.stub(:post_json, ->(url, body) { captured = [ url, body ]; Net::HTTPSuccess.new("1.1", "200", "OK") }) do
        with_config(build_config(trmnl_webhook_url: "https://trmnl.com/api/custom_plugins/abc")) do
          TrmnlPushJob.perform_now
        end
      end
    end
    assert_equal "https://trmnl.com/api/custom_plugins/abc", captured[0]
    assert_equal payload.to_json, captured[1]
  end

  test "raises when payload exceeds 2 kB" do
    huge = { "merge_variables" => { "blob" => "x" * 4000 } }
    stub_builder(huge) do
      with_config(build_config(trmnl_webhook_url: "https://example/")) do
        assert_raises(TrmnlPushJob::PayloadTooLarge) { TrmnlPushJob.perform_now }
      end
    end
  end

  test "logs a warning when the POST fails" do
    payload = { "merge_variables" => { "ts" => 1 } }
    logs = []
    Rails.logger.stub(:warn, ->(msg) { logs << msg }) do
      stub_builder(payload) do
        TrmnlPushJob.stub(:post_json, ->(*) { raise SocketError, "boom" }) do
          with_config(build_config(trmnl_webhook_url: "https://example/")) do
            assert_nothing_raised { TrmnlPushJob.perform_now }
          end
        end
      end
    end
    assert logs.any? { |m| m.to_s.include?("TRMNL push") && m.to_s.include?("boom") }, "expected a TRMNL push warning, got: #{logs.inspect}"
  end
end

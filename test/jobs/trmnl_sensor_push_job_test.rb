require "test_helper"
require "config_loader"

class TrmnlSensorPushJobTest < ActiveJob::TestCase
  def build_config(sensors_webhook_url:)
    plug = ConfigLoader::PlugCfg.new(id: "bkw", name: "BKW", role: :producer, driver: :shelly, ain: nil)
    mqtt = ConfigLoader::MqttCfg.new(host: "localhost", port: 1883, topic_prefix: "shellies")
    ConfigLoader::Config.new(
      electricity_price_eur_per_kwh: 0.32, timezone: "Europe/Berlin",
      mqtt: mqtt, fritz_poll: nil, plugs: [ plug ], fritz_box: nil, weather: nil,
      sensors: [], switchbot: nil,
      trmnl: ConfigLoader::TrmnlCfg.new(energy_webhook_url: nil,
                                         sensors_webhook_url: sensors_webhook_url),
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
    TrmnlSensorPayloadBuilder.stub(:new, ->(**) { fake }) { yield }
  end

  test "does nothing when sensors_webhook_url is not configured" do
    posted = []
    TrmnlSensorPushJob.stub(:post_json, ->(*args) { posted << args; nil }) do
      with_config(build_config(sensors_webhook_url: nil)) do
        TrmnlSensorPushJob.perform_now
      end
    end
    assert_empty posted
  end

  test "POSTs the payload to the configured sensors URL" do
    payload  = { "merge_variables" => { "stand" => "16:56", "sensors" => [] } }
    captured = nil
    stub_builder(payload) do
      TrmnlSensorPushJob.stub(:post_json, ->(url, body) { captured = [ url, body ]; Net::HTTPSuccess.new("1.1", "200", "OK") }) do
        with_config(build_config(sensors_webhook_url: "https://trmnl.com/api/custom_plugins/xyz")) do
          TrmnlSensorPushJob.perform_now
        end
      end
    end
    assert_equal "https://trmnl.com/api/custom_plugins/xyz", captured[0]
    assert_equal payload.to_json, captured[1]
  end

  test "raises when payload exceeds 2 kB" do
    huge = { "merge_variables" => { "blob" => "x" * 4000 } }
    stub_builder(huge) do
      with_config(build_config(sensors_webhook_url: "https://example/")) do
        assert_raises(TrmnlSensorPushJob::PayloadTooLarge) { TrmnlSensorPushJob.perform_now }
      end
    end
  end

  test "logs a warning when the POST fails" do
    payload = { "merge_variables" => { "stand" => "16:56", "sensors" => [] } }
    logs = []
    Rails.logger.stub(:warn, ->(msg) { logs << msg }) do
      stub_builder(payload) do
        TrmnlSensorPushJob.stub(:post_json, ->(*) { raise SocketError, "boom" }) do
          with_config(build_config(sensors_webhook_url: "https://example/")) do
            assert_nothing_raised { TrmnlSensorPushJob.perform_now }
          end
        end
      end
    end
    assert logs.any? { |m| m.to_s.include?("TRMNL sensor push") && m.to_s.include?("boom") }, "expected a TRMNL sensor push warning, got: #{logs.inspect}"
  end
end

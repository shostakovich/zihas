require "test_helper"
require "rack/test"
require "tempfile"
require "json"

class WebTest < Minitest::Test
  include Rack::Test::Methods

  def app
    @app ||= begin
      cfg = Tempfile.new(["cfg", ".yml"])
      cfg.write(<<~YAML); cfg.flush
        electricity_price_eur_per_kwh: 0.32
        timezone: Europe/Berlin
        poll:
          interval_seconds: 5
          timeout_seconds: 2
          circuit_breaker_threshold: 3
          circuit_breaker_probe_seconds: 30
        aggregator:
          run_at: "03:15"
          raw_retention_days: 7
        plugs:
          - id: bkw
            name: Balkonkraftwerk
            role: producer
            host: 10.0.0.1
          - id: fridge
            name: Kühlschrank
            role: consumer
            host: 10.0.0.2
      YAML

      ENV["CONFIG_PATH"]   = cfg.path
      ENV["DATABASE_PATH"] = ":memory:"
      require "web"
      Web
    end
  end

  def setup
    app  # ensure Web is loaded
    # Reset DB each test
    Web.settings.db[:samples].delete
  end

  def test_api_live_returns_offline_when_no_samples
    get "/api/live"
    assert_equal 200, last_response.status
    data = JSON.parse(last_response.body)
    assert_equal 2, data["plugs"].length
    assert data["plugs"].all? { |p| p["online"] == false }
  end

  def test_api_live_returns_current_values_after_sample
    now = Time.now.to_i
    Web.settings.db[:samples].insert(plug_id: "bkw", ts: now - 2, apower_w: 342.5, aenergy_wh: 1000.0)
    get "/api/live"
    bkw = JSON.parse(last_response.body)["plugs"].find { |p| p["id"] == "bkw" }
    assert_equal true, bkw["online"]
    assert_in_delta 342.5, bkw["apower_w"]
  end

  def test_api_live_marks_stale_sample_as_offline
    old = Time.now.to_i - 60
    Web.settings.db[:samples].insert(plug_id: "bkw", ts: old, apower_w: 1.0, aenergy_wh: 1.0)
    get "/api/live"
    bkw = JSON.parse(last_response.body)["plugs"].find { |p| p["id"] == "bkw" }
    assert_equal false, bkw["online"]
  end
end

require "test_helper"
require "rack/test"
require "tempfile"
require "json"
require "tzinfo"
require "date"
require "time"

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
    Web.settings.db[:daily_totals].delete
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

  def test_api_today_returns_per_minute_series_per_plug
    now = Time.now.to_i
    Web.settings.db[:samples].insert(plug_id: "bkw", ts: now - 3600,
                                     apower_w: 200.0, aenergy_wh: 100.0)
    Web.settings.db[:samples].insert(plug_id: "bkw", ts: now - 3540,
                                     apower_w: 300.0, aenergy_wh: 110.0)

    get "/api/today"
    assert_equal 200, last_response.status
    data = JSON.parse(last_response.body)
    bkw  = data["series"].find { |s| s["plug_id"] == "bkw" }
    refute_nil bkw
    assert bkw["points"].length >= 1
    point = bkw["points"].first
    assert point.key?("ts")
    assert point.key?("avg_power_w")
  end

  def test_api_today_summary_calculates_savings
    tz       = TZInfo::Timezone.get("Europe/Berlin")
    midnight = tz.local_to_utc(Time.parse("#{Date.today} 00:00:00")).to_i
    Web.settings.db[:samples].insert(plug_id: "bkw",    ts: midnight + 60,
                                     apower_w: 0, aenergy_wh: 0)
    Web.settings.db[:samples].insert(plug_id: "bkw",    ts: midnight + 3600,
                                     apower_w: 0, aenergy_wh: 1000.0)  # 1 kWh today
    Web.settings.db[:samples].insert(plug_id: "fridge", ts: midnight + 60,
                                     apower_w: 0, aenergy_wh: 500.0)
    Web.settings.db[:samples].insert(plug_id: "fridge", ts: midnight + 3600,
                                     apower_w: 0, aenergy_wh: 600.0)   # 0.1 kWh today

    get "/api/today/summary"
    data = JSON.parse(last_response.body)
    assert_in_delta 1000.0, data["produced_wh_today"]
    assert_in_delta 100.0,  data["consumed_wh_today"]
    assert_in_delta 0.32,   data["savings_eur_today"]
  end

  def test_api_today_summary_handles_meter_reset
    tz       = TZInfo::Timezone.get("Europe/Berlin")
    midnight = tz.local_to_utc(Time.parse("#{Date.today} 00:00:00")).to_i
    # fridge counter at 424,44 kWh, then resets to 0, then consumes 50 Wh
    Web.settings.db[:samples].insert(plug_id: "fridge", ts: midnight + 60,  apower_w: 0, aenergy_wh: 424_440.0)
    Web.settings.db[:samples].insert(plug_id: "fridge", ts: midnight + 120, apower_w: 0, aenergy_wh: 0.0)
    Web.settings.db[:samples].insert(plug_id: "fridge", ts: midnight + 180, apower_w: 0, aenergy_wh: 50.0)
    get "/api/today/summary"
    data = JSON.parse(last_response.body)
    assert_in_delta 50.0, data["consumed_wh_today"]
  end

  def test_api_today_summary_ignores_glitch_zero_then_jump_back
    # Fritz!DECT briefly returns 0 for getswitchenergy (firmware glitch)
    # and then snaps back to its real lifetime cumulative value. The jump
    # back UP must not be counted as consumption.
    tz       = TZInfo::Timezone.get("Europe/Berlin")
    midnight = tz.local_to_utc(Time.parse("#{Date.today} 00:00:00")).to_i
    Web.settings.db[:samples].insert(plug_id: "fridge", ts: midnight + 60,  apower_w: 145, aenergy_wh: 425_000.0)
    Web.settings.db[:samples].insert(plug_id: "fridge", ts: midnight + 65,  apower_w: 145, aenergy_wh: 0.0)
    Web.settings.db[:samples].insert(plug_id: "fridge", ts: midnight + 70,  apower_w: 145, aenergy_wh: 425_005.0)
    Web.settings.db[:samples].insert(plug_id: "fridge", ts: midnight + 75,  apower_w: 145, aenergy_wh: 425_010.0)
    get "/api/today/summary"
    data = JSON.parse(last_response.body)
    # Only the legitimate 5 Wh delta between the last two samples is counted.
    assert_in_delta 5.0, data["consumed_wh_today"]
  end

  def test_api_history_returns_n_days
    tz     = TZInfo::Timezone.get("Europe/Berlin")
    today  = Date.today
    7.times do |i|
      d = today - (i + 1)
      Web.settings.db[:daily_totals].insert(plug_id: "bkw", date: d.to_s, energy_wh: 1000 + i * 100)
    end
    get "/api/history?days=5"
    data = JSON.parse(last_response.body)
    bkw  = data["series"].find { |s| s["plug_id"] == "bkw" }
    assert_equal 5, bkw["points"].length
    assert bkw["points"].first["date"] < bkw["points"].last["date"]  # sorted ascending
  end

  def test_root_serves_dashboard_html
    get "/"
    assert_equal 200, last_response.status
    assert_match(/Zipfelmaus/, last_response.body)
    assert_match(/id="today-chart"/, last_response.body)
  end
end

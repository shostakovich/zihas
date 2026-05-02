require "test_helper"

class ApiControllerTest < ActionDispatch::IntegrationTest
  setup do
    Sample.delete_all
    DailyTotal.delete_all

    # Minimal config stub so controller can call app_config
    plug_bkw    = ConfigLoader::PlugCfg.new(id: "bkw",    name: "Balkonkraftwerk", role: :producer, driver: :shelly, host: "10.0.0.1", ain: nil)
    plug_fridge = ConfigLoader::PlugCfg.new(id: "fridge", name: "Kühlschrank",     role: :consumer, driver: :shelly, host: "10.0.0.2", ain: nil)

    poll = ConfigLoader::PollCfg.new(
      interval_seconds: 5, timeout_seconds: 2,
      circuit_breaker_threshold: 3, circuit_breaker_probe_seconds: 30
    )

    @config = ConfigLoader::Config.new(
      electricity_price_eur_per_kwh: 0.32,
      timezone: "Europe/Berlin",
      poll: poll,
      aggregator: nil,
      plugs: [ plug_bkw, plug_fridge ],
      fritz_box: nil
    )

    # Stub Rails.application.ziwoas_app so the controller can access config
    app_stub = Struct.new(:config).new(@config)
    Rails.application.ziwoas_app = app_stub
  end

  teardown do
    Rails.application.ziwoas_app = nil
  end

  # --- /api/live ---

  test "GET /api/live returns offline when no samples" do
    get "/api/live", as: :json
    assert_response :ok

    data = response.parsed_body
    assert_equal 2, data["plugs"].length
    assert data["plugs"].all? { |p| p["online"] == false }
  end

  test "GET /api/live returns online with current values after fresh sample" do
    now = Time.now.to_i
    Sample.create!(plug_id: "bkw", ts: now - 2, apower_w: 342.5, aenergy_wh: 1000.0)

    get "/api/live", as: :json
    assert_response :ok

    bkw = response.parsed_body["plugs"].find { |p| p["id"] == "bkw" }
    assert_equal true, bkw["online"]
    assert_in_delta 342.5, bkw["apower_w"]
  end

  test "GET /api/live marks stale sample as offline" do
    old = Time.now.to_i - 60
    Sample.create!(plug_id: "bkw", ts: old, apower_w: 1.0, aenergy_wh: 1.0)

    get "/api/live", as: :json
    assert_response :ok

    bkw = response.parsed_body["plugs"].find { |p| p["id"] == "bkw" }
    assert_equal false, bkw["online"]
  end

  # --- /api/today ---

  test "GET /api/today returns series per plug" do
    now = Time.now.to_i
    Sample.create!(plug_id: "bkw", ts: now - 3600, apower_w: 200.0, aenergy_wh: 100.0)
    Sample.create!(plug_id: "bkw", ts: now - 3540, apower_w: 300.0, aenergy_wh: 110.0)

    get "/api/today", as: :json
    assert_response :ok

    data = response.parsed_body
    assert data["series"].any? { |s| s["plug_id"] == "bkw" }
    bkw = data["series"].find { |s| s["plug_id"] == "bkw" }
    assert bkw["points"].length >= 1
    assert bkw["points"].first.key?("ts")
    assert bkw["points"].first.key?("avg_power_w")
  end

  # --- /api/today/summary ---

  test "GET /api/today/summary calculates energy and savings" do
    tz       = TZInfo::Timezone.get("Europe/Berlin")
    midnight = tz.local_to_utc(Time.parse("#{Date.today} 00:00:00")).to_i

    Sample.create!(plug_id: "bkw",    ts: midnight + 60,   apower_w: 0, aenergy_wh: 0.0)
    Sample.create!(plug_id: "bkw",    ts: midnight + 3600, apower_w: 0, aenergy_wh: 1000.0)
    Sample.create!(plug_id: "fridge", ts: midnight + 60,   apower_w: 0, aenergy_wh: 500.0)
    Sample.create!(plug_id: "fridge", ts: midnight + 3600, apower_w: 0, aenergy_wh: 600.0)

    get "/api/today/summary", as: :json
    assert_response :ok

    data = response.parsed_body
    assert_in_delta 1000.0, data["produced_wh_today"]
    assert_in_delta 100.0,  data["consumed_wh_today"]
    assert_in_delta 0.32,   data["savings_eur_today"]
  end

  # --- /api/history ---

  test "GET /api/history returns requested number of days" do
    today = Date.today
    7.times do |i|
      DailyTotal.create!(plug_id: "bkw", date: (today - (i + 1)).to_s, energy_wh: 1000 + i * 100)
    end

    get "/api/history?days=5", as: :json
    assert_response :ok

    data = response.parsed_body
    bkw = data["series"].find { |s| s["plug_id"] == "bkw" }
    assert_equal 5, bkw["points"].length
    # sorted ascending
    assert bkw["points"].first["date"] < bkw["points"].last["date"]
  end

  # --- / ---

  test "GET / serves dashboard HTML" do
    get "/"
    assert_response :ok
    assert_select "h1", count: 0
    assert_select ".chart-card .chart-frame", minimum: 3
  end
end

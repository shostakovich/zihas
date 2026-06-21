require "test_helper"

class ApiControllerTest < ActionDispatch::IntegrationTest
  setup do
    Sample.delete_all
    DailyTotal.delete_all
    SolakonReading.delete_all
  end

  # --- /api/live ---

  test "GET /api/live returns offline when no samples" do
    get "/api/live", as: :json
    assert_response :ok

    data = response.parsed_body
    assert data["plugs"].length >= 2
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
    old = Time.now.to_i - 130
    Sample.create!(plug_id: "bkw", ts: old, apower_w: 1.0, aenergy_wh: 1.0)

    get "/api/live", as: :json
    assert_response :ok

    bkw = response.parsed_body["plugs"].find { |p| p["id"] == "bkw" }
    assert_equal false, bkw["online"]
  end

  test "GET /api/live includes fresh Solakon energy flow" do
    travel_to Time.zone.local(2026, 6, 18, 12, 0, 0) do
      now = Time.current
      cfg = live_config_with_solakon(stale_after_s: 120)

      Sample.create!(plug_id: "desk", ts: now.to_i - 2, apower_w: 120.0, aenergy_wh: 1.0)
      Sample.create!(plug_id: "heatpump", ts: now.to_i - 2, apower_w: 80.0, aenergy_wh: 1.0)
      SolakonReading.create!(
        taken_at: now - 2.seconds,
        active_power_w: 260,
        pv_power_w: 310,
        battery_power_w: 50,
        battery_soc_pct: 84
      )

      ConfigLoader.stub(:app_config, cfg) do
        get "/api/live", as: :json
      end
      assert_response :ok

      energy_flow = response.parsed_body["energy_flow"]
      assert_equal true, energy_flow["solakon_online"]
      assert_in_delta 200.0, energy_flow["home_w"]
      assert_in_delta 260.0, energy_flow["solakon_ac_w"]
      assert_in_delta 310.0, energy_flow["solar_w"]
      assert_equal 84, energy_flow["battery_soc_pct"]
      assert_in_delta 50.0, energy_flow["battery_w"]
      assert_in_delta(-60.0, energy_flow["grid_w"])
      assert_equal({
        "solar_to_home_w" => 200.0,
        "solar_to_grid_w" => 60.0,
        "solar_to_battery_w" => 50.0,
        "grid_to_home_w" => 0.0,
        "grid_to_battery_w" => 0.0,
        "battery_to_home_w" => 0.0
      }, energy_flow["flows"])
    end
  end


  test "GET /api/live uses grid reference to correct solar-to-battery flow" do
    travel_to Time.zone.local(2026, 6, 18, 12, 0, 0) do
      now = Time.current
      cfg = live_config_with_solakon(stale_after_s: 120)

      Sample.create!(plug_id: "desk", ts: now.to_i - 2, apower_w: 200.0, aenergy_wh: 1.0)
      SolakonReading.create!(
        taken_at: now - 2.seconds,
        active_power_w: 260,
        pv_power_w: 400,
        battery_power_w: 50,
        battery_soc_pct: 84
      )

      ConfigLoader.stub(:app_config, cfg) do
        get "/api/live", as: :json
      end
      assert_response :ok

      flows = response.parsed_body.dig("energy_flow", "flows")
      assert_equal 200.0, flows.fetch("solar_to_home_w")
      assert_equal 60.0, flows.fetch("solar_to_grid_w")
      assert_equal 140.0, flows.fetch("solar_to_battery_w")
      assert_equal 0.0, flows.fetch("battery_to_home_w")
    end
  end

  test "GET /api/live splits house supply between solar battery and grid while discharging" do
    travel_to Time.zone.local(2026, 6, 18, 12, 0, 0) do
      now = Time.current
      cfg = live_config_with_solakon(stale_after_s: 120)

      Sample.create!(plug_id: "desk", ts: now.to_i - 2, apower_w: 200.0, aenergy_wh: 1.0)
      SolakonReading.create!(
        taken_at: now - 2.seconds,
        active_power_w: 150,
        pv_power_w: 100,
        battery_power_w: -50,
        battery_soc_pct: 84
      )

      ConfigLoader.stub(:app_config, cfg) do
        get "/api/live", as: :json
      end
      assert_response :ok

      flows = response.parsed_body.dig("energy_flow", "flows")
      assert_equal 100.0, flows.fetch("solar_to_home_w")
      assert_equal 0.0, flows.fetch("solar_to_grid_w")
      assert_equal 0.0, flows.fetch("solar_to_battery_w")
      assert_equal 50.0, flows.fetch("grid_to_home_w")
      assert_equal 50.0, flows.fetch("battery_to_home_w")
    end
  end

  test "GET /api/live reports unknown home and grid when consumer samples are stale" do
    travel_to Time.zone.local(2026, 6, 18, 12, 0, 0) do
      now = Time.current
      cfg = live_config_with_solakon(stale_after_s: 120)

      Sample.create!(plug_id: "desk", ts: now.to_i - 130, apower_w: 120.0, aenergy_wh: 1.0)
      Sample.create!(plug_id: "heatpump", ts: now.to_i - 130, apower_w: 80.0, aenergy_wh: 1.0)
      SolakonReading.create!(
        taken_at: now - 2.seconds,
        active_power_w: 260,
        pv_power_w: 310,
        battery_power_w: 50,
        battery_soc_pct: 84
      )

      ConfigLoader.stub(:app_config, cfg) do
        get "/api/live", as: :json
      end
      assert_response :ok

      energy_flow = response.parsed_body["energy_flow"]
      assert_equal true, energy_flow["solakon_online"]
      assert_nil energy_flow["home_w"]
      assert_in_delta 260.0, energy_flow["solakon_ac_w"]
      assert_nil energy_flow["grid_w"]
    end
  end

  test "GET /api/live sums only the fresh consumer plugs and ignores stale ones" do
    travel_to Time.zone.local(2026, 6, 18, 12, 0, 0) do
      now = Time.current
      cfg = live_config_with_solakon(stale_after_s: 120)

      Sample.create!(plug_id: "desk", ts: now.to_i - 2, apower_w: 120.0, aenergy_wh: 1.0)       # fresh
      Sample.create!(plug_id: "heatpump", ts: now.to_i - 130, apower_w: 80.0, aenergy_wh: 1.0)  # stale -> ignored
      SolakonReading.create!(
        taken_at: now - 2.seconds,
        active_power_w: 260,
        pv_power_w: 310,
        battery_power_w: 50,
        battery_soc_pct: 84
      )

      ConfigLoader.stub(:app_config, cfg) do
        get "/api/live", as: :json
      end
      assert_response :ok

      energy_flow = response.parsed_body["energy_flow"]
      assert_in_delta 120.0, energy_flow["home_w"]      # only the fresh desk plug, heatpump dropped
      assert_in_delta(-140.0, energy_flow["grid_w"])    # 120 - 260
    end
  end

  test "GET /api/live marks stale Solakon energy flow unavailable" do
    travel_to Time.zone.local(2026, 6, 18, 12, 0, 0) do
      now = Time.current
      cfg = live_config_with_solakon(stale_after_s: 120)

      Sample.create!(plug_id: "desk", ts: now.to_i - 2, apower_w: 120.0, aenergy_wh: 1.0)
      Sample.create!(plug_id: "heatpump", ts: now.to_i - 2, apower_w: 80.0, aenergy_wh: 1.0)
      SolakonReading.create!(
        taken_at: now - 121.seconds,
        active_power_w: 260,
        pv_power_w: 310,
        battery_power_w: 50,
        battery_soc_pct: 84
      )

      ConfigLoader.stub(:app_config, cfg) do
        get "/api/live", as: :json
      end
      assert_response :ok

      energy_flow = response.parsed_body["energy_flow"]
      assert_equal false, energy_flow["solakon_online"]
      assert_in_delta 200.0, energy_flow["home_w"]
      assert_nil energy_flow["solakon_ac_w"]
      assert_nil energy_flow["solar_w"]
      assert_nil energy_flow["battery_soc_pct"]
      assert_nil energy_flow["battery_w"]
      assert_nil energy_flow["grid_w"]
    end
  end

  test "GET /api/live marks Solakon energy flow unavailable when monitoring disabled" do
    travel_to Time.zone.local(2026, 6, 18, 12, 0, 0) do
      now = Time.current
      cfg = live_config_with_solakon(stale_after_s: 120, monitoring_enabled: false)

      Sample.create!(plug_id: "desk", ts: now.to_i - 2, apower_w: 120.0, aenergy_wh: 1.0)
      Sample.create!(plug_id: "heatpump", ts: now.to_i - 2, apower_w: 80.0, aenergy_wh: 1.0)
      SolakonReading.create!(
        taken_at: now - 2.seconds,
        active_power_w: 260,
        pv_power_w: 310,
        battery_power_w: 50,
        battery_soc_pct: 84
      )

      ConfigLoader.stub(:app_config, cfg) do
        get "/api/live", as: :json
      end
      assert_response :ok

      energy_flow = response.parsed_body["energy_flow"]
      assert_equal false, energy_flow["solakon_online"]
      assert_in_delta 200.0, energy_flow["home_w"]
      assert_nil energy_flow["solakon_ac_w"]
      assert_nil energy_flow["solar_w"]
      assert_nil energy_flow["battery_soc_pct"]
      assert_nil energy_flow["battery_w"]
      assert_nil energy_flow["grid_w"]
    end
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
    assert_in_delta 1000.0 * 0.2902 / 1000.0, data["savings_eur_today"], 0.001
  end

  test "GET /api/today/summary includes self-consumption fields" do
    tz       = TZInfo::Timezone.get("Europe/Berlin")
    midnight = tz.local_to_utc(Time.parse("#{Date.today} 00:00:00")).to_i

    (0..3600).step(60) do |dt|
      Sample.create!(plug_id: "bkw",    ts: midnight + dt, apower_w: 200.0, aenergy_wh: 200.0 * dt / 3600.0)
      Sample.create!(plug_id: "fridge", ts: midnight + dt, apower_w: 100.0, aenergy_wh: 100.0 * dt / 3600.0)
    end

    get "/api/today/summary", as: :json
    assert_response :ok

    data = response.parsed_body
    assert data.key?("self_consumed_wh_today")
    assert data.key?("autarky_ratio")
    assert data.key?("self_consumption_ratio")
    assert_in_delta 100.0, data["self_consumed_wh_today"], 2.0
    assert_in_delta 1.0,   data["autarky_ratio"],          0.05
    assert_in_delta 0.5,   data["self_consumption_ratio"], 0.05
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
    assert_select "h1", text: "Dashboard", count: 1
    assert_select ".chart-card .chart-frame", minimum: 3
  end
  private

  def live_config_with_solakon(stale_after_s:, monitoring_enabled: true)
    ConfigLoader::Config.new(
      electricity_price_eur_per_kwh: 0.32,
      timezone: "Europe/Berlin",
      mqtt: ConfigLoader::MqttCfg.new(host: "localhost", port: 1883, topic_prefix: "shellies"),
      plugs: [
        ConfigLoader::PlugCfg.new(id: "bkw", name: "BKW", role: :producer, driver: :shelly, ain: nil),
        ConfigLoader::PlugCfg.new(id: "desk", name: "Desk", role: :consumer, driver: :shelly, ain: nil),
        ConfigLoader::PlugCfg.new(id: "heatpump", name: "Heatpump", role: :consumer, driver: :shelly, ain: nil)
      ],
      sensors: [],
      trmnl: ConfigLoader::TrmnlCfg.new(energy_webhook_url: nil, sensors_webhook_url: nil),
      solakon: ConfigLoader::SolakonCfg.new(
        host: "127.0.0.1",
        port: 502,
        unit_id: 1,
        monitoring_enabled: monitoring_enabled,
        control_enabled: false,
        stale_after_s: stale_after_s
      )
    )
  end
end

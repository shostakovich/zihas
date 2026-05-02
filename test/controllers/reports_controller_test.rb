require "test_helper"

class ReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    DailyTotal.delete_all

    plug_bkw = ConfigLoader::PlugCfg.new(id: "bkw", name: "Balkonkraftwerk", role: :producer, driver: :shelly, host: "10.0.0.1", ain: nil)
    plug_fridge = ConfigLoader::PlugCfg.new(id: "fridge", name: "Kuehlschrank", role: :consumer, driver: :shelly, host: "10.0.0.2", ain: nil)
    poll = ConfigLoader::PollCfg.new(
      interval_seconds: 5,
      timeout_seconds: 2,
      circuit_breaker_threshold: 3,
      circuit_breaker_probe_seconds: 30
    )

    config = ConfigLoader::Config.new(
      electricity_price_eur_per_kwh: 0.32,
      timezone: "Europe/Berlin",
      poll: poll,
      aggregator: nil,
      plugs: [ plug_bkw, plug_fridge ],
      fritz_box: nil
    )

    Rails.application.ziwoas_app = Struct.new(:config).new(config)
  end

  teardown do
    Rails.application.ziwoas_app = nil
  end

  test "reports page renders" do
    get "/reports"

    assert_response :success
    assert_select "h1", "Berichte"
  end

  test "reports page accepts custom range params" do
    get "/reports", params: { start_date: "2026-04-01", end_date: "2026-04-07" }

    assert_response :success
    assert_select "input[name='start_date'][value='2026-04-01']"
    assert_select "input[name='end_date'][value='2026-04-07']"
  end

  test "reports page renders summary ranking and chart payload" do
    DailyTotal.create!(plug_id: "bkw", date: "2026-04-10", energy_wh: 2000)

    get "/reports"

    assert_response :success
    assert_select ".report-summary-card", minimum: 3
    assert_select "[data-energy-report-target='dailyCanvas']", 1
    assert_select "[data-energy-report-target='detailCanvas']", 1
    assert_select "script[data-energy-report-target='payload']", 1
  end

  test "reports page shows empty state without data" do
    get "/reports"

    assert_response :success
    assert_select ".empty-state", text: /Noch keine Berichtsdaten/
  end
end

require "test_helper"

class SolakonControllerTest < ActionDispatch::IntegrationTest
  setup do
    SolakonReading.delete_all
    SolakonSnapshot.delete_all if defined?(SolakonSnapshot)
  end

  test "page renders single continuous Solakon overview" do
    get "/solakon"

    assert_response :success
    assert_select "h1", text: "PV", count: 1
    assert_select "[data-controller='solakon']", 1
    assert_select ".section-label", text: "Energiefluss"
    assert_select ".section-label", text: "Steuerung"
    assert_select ".section-label", text: "Panels"
    assert_select ".section-label", text: "Speicher"
    assert_select ".section-label", text: "Solakon-Verlauf"
    assert_select ".section-label", text: "Status"
    assert_operator response.body.index("Status"), :<, response.body.index("Steuerung")
    assert_select "[role='tablist']", count: 0
    assert_no_match(/SOH|EPS|46613|39067|Modbus/, response.body)
    assert_match(/Außensteckdose/, response.body)
    assert_match(/Auto-Regelung/, response.body)
    assert_match(/Batteriegesundheit/, response.body)
    assert_select "canvas[data-solakon-target='historyCanvas']", 1
    assert_select "script[data-solakon-target='historyPayload']", 1
    assert_select "[data-solakon-target='balanceRows']", 1
    assert_select "input[data-solakon-target='epsToggle'][data-action='change->solakon#toggleEps']", 1
    assert_select "input[data-solakon-target='autoRegulationToggle'][data-action='change->solakon#toggleAutoRegulation']", 1
  end

  test "page reuses four-node energy flow with Solakon targets" do
    get "/solakon"

    assert_response :success
    assert_select "svg[viewBox='0 0 400 320']", 1
    assert_select "[data-solakon-target='efPvW']", 1
    assert_select "[data-solakon-target='efGridW']", 1
    assert_select "[data-solakon-target='efConsumerW']", 1
    assert_select "[data-solakon-target='efBatterySoc']", 1
    assert_select "[data-solakon-target='efBatteryW']", 1
    assert_select "[data-solakon-target='efDotsSolarHome']", 1
    assert_select "image[href*='solakon_battery_normal']", minimum: 1
    assert_select "image[data-solakon-target='efBatteryImage'][data-battery-state-normal*='solakon_battery_normal']", 1
    assert_select "image[data-solakon-target='efBatteryImage'][data-battery-state-charging*='solakon_battery_charging']", 1
    assert_select "image[data-solakon-target='efBatteryImage'][data-battery-state-low*='solakon_battery_low']", 1
    assert_select "image[data-solakon-target='efBatteryImage'][data-battery-state-fault*='solakon_battery_fault']", 1
  end

  test "history endpoint returns selected range payload" do
    SolakonSnapshot.create!(taken_at: 10.minutes.ago, pv1_power_w: 100, pv2_power_w: 50, battery_power_w: 20, grid_power_w: 30)

    get "/solakon/history.json", params: { range: "24h" }

    assert_response :success
    data = response.parsed_body
    assert_equal "24h", data["range"]
    assert_equal [ "PV", "Akku", "Netz", "0 W" ], data.dig("chart", "datasets").map { |dataset| dataset.fetch("label") }
  end

  test "page renders controls, panel, storage, balance, and status labels without protocol language" do
    SolakonSnapshot.create!(
      taken_at: Time.current,
      pv1_power_w: 210,
      pv1_voltage_v: 41.0,
      pv1_current_a: 5.12,
      pv2_power_w: 198,
      pv2_voltage_v: 40.5,
      pv2_current_a: 4.88,
      pv3_power_w: 0,
      pv3_voltage_v: 0,
      pv3_current_a: 0,
      battery_health_pct: 97,
      battery_voltage_v: 51.3,
      battery_current_a: 4.2,
      battery_temperature_c: 24.8,
      remaining_energy_wh: 123.4,
      full_charge_capacity_ah: 51.2,
      design_energy_wh: 1920.0,
      inverter_temperature_c: 34.1,
      eps_enabled: true,
      eps_voltage_v: 230.1,
      eps_power_w: 125
    )

    get "/solakon"

    assert_response :success
    assert_select ".solakon-control-card", 2
    assert_select ".solakon-panel-card", 2
    assert_select ".solakon-panel-card", text: /Panel 3/, count: 0
    assert_select ".solakon-storage-grid .tile-label", text: "Ladestand"
    assert_select ".solakon-storage-grid .tile-label", text: "Batteriegesundheit"
    assert_select ".solakon-storage-grid .tile-label", text: "Aktuelle Batterieleistung"
    assert_select ".solakon-storage-grid .tile-label", text: "Batteriespannung"
    assert_select ".solakon-storage-grid .tile-label", text: "Batteriestrom"
    assert_select ".solakon-storage-grid .tile-label", text: "Speichertemperatur"
    assert_select ".solakon-storage-grid .tile-label", text: "Ladezyklen", count: 0
    assert_select ".solakon-balance-row", minimum: 6
    assert_no_match(/SOH|EPS|Modbus|Register|39067|46613|Fault\d|Alarm \d/, response.body)
  end

  test "status renders one relevant battery character with short description" do
    SolakonReading.create!(
      taken_at: Time.current,
      active_power_w: 260,
      pv_power_w: 310,
      battery_power_w: 80,
      battery_soc_pct: 84,
      battery_temperature_c: 24.8
    )

    get "/solakon"

    assert_response :success
    assert_select ".solakon-status-figure img[data-solakon-battery-state]", 1
    assert_select ".solakon-status-figure img[data-solakon-battery-state=charging][src*=solakon_battery_charging]", 1
    assert_select ".solakon-status-summary", text: /Akku lädt gerade/
    assert_select ".solakon-battery-states", count: 0
  end
end

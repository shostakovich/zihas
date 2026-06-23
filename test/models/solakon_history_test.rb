require "test_helper"

class SolakonHistoryTest < ActiveSupport::TestCase
  setup { SolakonSnapshot.delete_all }

  test "payload builds signed chart series and balance rows from snapshots" do
    travel_to Time.zone.local(2026, 6, 20, 12, 0, 0) do
      # Four snapshots, 2 min apart, so the Außensteckdose integration runs over
      # three intervals. active_power_w: +600, +600, -600, -600.
      #   600→600  (120 s, avg +600 W): +20 Wh delivered
      #   600→-600 (120 s, avg    0 W): 0 (zero crossing)
      #   -600→-600(120 s, avg -600 W): +20 Wh drawn
      # ⇒ delivered 0,02 kWh, drawn 0,02 kWh, time-weighted mean 0 W.
      SolakonSnapshot.create!(
        taken_at: 6.minutes.ago,
        pv1_power_w: 100, pv2_power_w: 50, battery_power_w: 20, active_power_w: 600,
        pv_total_kwh: 10.0, battery_charge_total_kwh: 5.0, battery_discharge_total_kwh: 3.0
      )
      SolakonSnapshot.create!(
        taken_at: 4.minutes.ago,
        pv1_power_w: 150, pv2_power_w: 75, battery_power_w: -40, active_power_w: 600,
        pv_total_kwh: 10.4, battery_charge_total_kwh: 5.1, battery_discharge_total_kwh: 3.1
      )
      SolakonSnapshot.create!(
        taken_at: 2.minutes.ago,
        pv1_power_w: 100, pv2_power_w: 50, battery_power_w: 30, active_power_w: -600,
        pv_total_kwh: 10.8, battery_charge_total_kwh: 5.2, battery_discharge_total_kwh: 3.2
      )
      SolakonSnapshot.create!(
        taken_at: Time.current,
        pv1_power_w: 120, pv2_power_w: 80, battery_power_w: -10, active_power_w: -600,
        pv_total_kwh: 11.2, battery_charge_total_kwh: 5.4, battery_discharge_total_kwh: 3.3
      )

      payload = SolakonHistory.new(range_key: "24h", now: Time.current).payload

      assert_equal "24h", payload.fetch(:range)
      assert_equal [ "PV", "Akku", "Außensteckdose", "0 W" ], payload.dig(:chart, :datasets).map { |dataset| dataset.fetch(:label) }
      assert_equal [ 150.0, 225.0, 150.0, 200.0 ], payload.dig(:chart, :datasets).first.fetch(:data)
      assert_equal [ 20.0, -40.0, 30.0, -10.0 ], payload.dig(:chart, :datasets)[1].fetch(:data)
      assert_equal [ 600.0, 600.0, -600.0, -600.0 ], payload.dig(:chart, :datasets)[2].fetch(:data)
      assert_equal [ 0, 0, 0, 0 ], payload.dig(:chart, :datasets)[3].fetch(:data)

      rows = payload.fetch(:balance_rows)
      assert_equal [ "PV-Erzeugung", "Akku geladen", "Akku entladen", "Ins Hausnetz geliefert", "Aus Hausnetz gezogen", "Ø Außensteckdose" ], rows.map { |row| row.fetch(:label) }
      assert_equal "1,20 kWh", rows[0].fetch(:value)
      assert_equal "0,40 kWh", rows[1].fetch(:value)
      assert_equal "0,30 kWh", rows[2].fetch(:value)
      assert_equal "0,02 kWh", rows[3].fetch(:value)
      assert_equal "0,02 kWh", rows[4].fetch(:value)
      assert_equal "0,00 W", rows[5].fetch(:value)
    end
  end

  test "empty payload is stable" do
    payload = SolakonHistory.new(range_key: "7d", now: Time.zone.local(2026, 6, 20, 12, 0, 0)).payload

    assert_equal "7d", payload.fetch(:range)
    assert_equal [], payload.dig(:chart, :labels)
    assert_equal "Keine Solakon-Historie", payload.fetch(:message)
  end
end

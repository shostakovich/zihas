require "test_helper"

class SolakonSnapshotJobTest < ActiveJob::TestCase
  class FakeClient
    attr_reader :calls

    def initialize(snapshot: nil, fail: false)
      @snapshot = snapshot
      @fail = fail
      @calls = []
    end

    def read_snapshot
      @calls << :read_snapshot
      raise SolakonClient::Error, "down" if @fail
      @snapshot
    end
  end

  Sol = Struct.new(:host, :port, :unit_id, :monitoring_enabled, :control_enabled, :stale_after_s, keyword_init: true)
  Cfg = Struct.new(:solakon, keyword_init: true)

  setup { SolakonSnapshot.delete_all }

  def config(monitoring_enabled: true, solakon: true)
    Cfg.new(solakon: (Sol.new(host: "h", port: 502, unit_id: 1, monitoring_enabled: monitoring_enabled, control_enabled: false, stale_after_s: 120) if solakon))
  end

  def snapshot_data
    SolakonClient::SnapshotData.new(
      panels: [
        SolakonClient::PanelData.new(index: 1, voltage_v: 41.0, current_a: 5.12, power_w: 210),
        SolakonClient::PanelData.new(index: 2, voltage_v: 40.5, current_a: 4.88, power_w: 198),
        SolakonClient::PanelData.new(index: 3, voltage_v: 0.0, current_a: 0.0, power_w: 0),
        SolakonClient::PanelData.new(index: 4, voltage_v: 0.0, current_a: 0.0, power_w: 0)
      ],
      battery_voltage_v: 51.3,
      battery_current_a: 4.2,
      battery_temperature_c: 24.8,
      battery_min_temperature_c: 21.1,
      battery_health_pct: 97,
      remaining_energy_wh: 123.4,
      full_charge_capacity_ah: 51.2,
      design_energy_wh: 1920.0,
      inverter_temperature_c: 34.1,
      grid_power_w: 100,
      eps_enabled: true,
      eps_voltage_v: 230.1,
      eps_power_w: 125,
      status1: 4,
      status3: 0,
      alarm1: 0,
      alarm2: 0,
      alarm3: 0,
      bms_faults: [ 0, 0, 0, 0, 0, 0 ],
      pv_total_kwh: 123.45,
      battery_charge_total_kwh: 67.89,
      battery_discharge_total_kwh: 45.67,
      grid_export_total_kwh: 22.22,
      grid_import_total_kwh: 33.33
    )
  end

  test "persists slow snapshot when monitoring is enabled" do
    now = Time.zone.local(2026, 6, 20, 12, 0, 0)
    client = FakeClient.new(snapshot: snapshot_data)

    ConfigLoader.stub(:app_config, config) do
      assert_difference -> { SolakonSnapshot.count }, 1 do
        SolakonSnapshotJob.new.perform(client: client, now: now)
      end
    end

    row = SolakonSnapshot.last
    assert_equal [ :read_snapshot ], client.calls
    assert_equal now, row.taken_at
    assert_equal 210, row.pv1_power_w
    assert_equal 198, row.pv2_power_w
    assert_equal 97, row.battery_health_pct
    assert_equal true, row.eps_enabled
    assert_in_delta 123.45, row.pv_total_kwh, 0.001
  end

  test "does not read when Solakon monitoring is disabled" do
    client = FakeClient.new(snapshot: snapshot_data)

    ConfigLoader.stub(:app_config, config(monitoring_enabled: false)) do
      assert_no_difference -> { SolakonSnapshot.count } do
        SolakonSnapshotJob.new.perform(client: client)
      end
    end

    assert_empty client.calls
  end

  test "read failure is logged and does not persist" do
    client = FakeClient.new(fail: true)

    ConfigLoader.stub(:app_config, config) do
      assert_no_difference -> { SolakonSnapshot.count } do
        assert_nothing_raised { SolakonSnapshotJob.new.perform(client: client) }
      end
    end
  end
end

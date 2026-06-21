require "test_helper"

class SolakonSnapshotTest < ActiveSupport::TestCase
  test "requires taken_at and validates numeric fields" do
    snapshot = SolakonSnapshot.new(pv1_power_w: "bright")

    assert_not snapshot.valid?
    assert_includes snapshot.errors[:taken_at], "can't be blank"
    assert_includes snapshot.errors[:pv1_power_w], "is not a number"
  end

  test "connected_panels returns only panel one and two when connected" do
    snapshot = SolakonSnapshot.new(
      pv1_power_w: 210, pv1_voltage_v: 41.0, pv1_current_a: 5.12,
      pv2_power_w: 198, pv2_voltage_v: 40.5, pv2_current_a: 4.88,
      pv3_power_w: 50, pv3_voltage_v: 40.0, pv3_current_a: 1.0,
      pv4_power_w: 60, pv4_voltage_v: 40.0, pv4_current_a: 1.5
    )

    assert_equal [
      { index: 1, label: "Panel 1", power_w: 210.0, voltage_v: 41.0, current_a: 5.12 },
      { index: 2, label: "Panel 2", power_w: 198.0, voltage_v: 40.5, current_a: 4.88 }
    ], snapshot.connected_panels
  end

  test "status_messages delegates to user-facing decoder" do
    snapshot = SolakonSnapshot.new(status1: 4, status3: 0, alarm1: 0, alarm2: 8, alarm3: 0, bms_faults: [ 0, 0, 0, 0, 0, 0 ])

    assert_includes snapshot.status_messages, "Wechselrichter in Betrieb"
    assert_includes snapshot.status_messages, "Temperatur zu hoch"
    assert snapshot.status_messages.none? { |message| message.match?(/SOH|EPS|390|Alarm 2|Bit/) }
  end
end

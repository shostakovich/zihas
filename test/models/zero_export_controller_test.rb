require "test_helper"

class ZeroExportControllerTest < Minitest::Test
  # --- normal mode (recovery: false) ---

  def test_follows_fresh_consumption
    assert_equal 250, ZeroExportController.target_output_w(
      consumption_w: 250.4, floor_w: 100, pv_power_w: 0, recovery: false)
  end

  def test_fresh_consumption_below_floor_is_NOT_raised_to_floor
    assert_equal 40, ZeroExportController.target_output_w(
      consumption_w: 40, floor_w: 100, pv_power_w: 0, recovery: false)
  end

  def test_falls_back_to_floor_when_consumption_unknown
    assert_equal 146, ZeroExportController.target_output_w(
      consumption_w: nil, floor_w: 146, pv_power_w: 0, recovery: false)
  end

  def test_capped_at_max_output
    assert_equal 800, ZeroExportController.target_output_w(
      consumption_w: 1500, floor_w: 100, pv_power_w: 0, recovery: false)
  end

  def test_never_negative
    assert_equal 0, ZeroExportController.target_output_w(
      consumption_w: -50, floor_w: 100, pv_power_w: 0, recovery: false)
  end

  # --- recovery mode (recovery: true) ---

  def test_recovery_caps_at_pv_minus_reserve_so_battery_charges
    # load 170, PV 100 -> never discharge; reserve 30 for charging -> 70
    assert_equal 70, ZeroExportController.target_output_w(
      consumption_w: 170, floor_w: 0, pv_power_w: 100, recovery: true)
  end

  def test_recovery_still_follows_consumption_when_below_pv_headroom
    # load 40, PV 100 -> 40 already leaves >30W PV to charge, no need to cap
    assert_equal 40, ZeroExportController.target_output_w(
      consumption_w: 40, floor_w: 0, pv_power_w: 100, recovery: true)
  end

  def test_recovery_with_no_pv_commands_zero
    assert_equal 0, ZeroExportController.target_output_w(
      consumption_w: 170, floor_w: 0, pv_power_w: 0, recovery: true)
  end

  def test_constants
    assert_equal 800, ZeroExportController::MAX_OUTPUT_W
    assert_equal 10, ZeroExportController::MIN_SOC_PCT
    assert_equal 13, ZeroExportController::ENTER_RECOVERY_SOC
    assert_equal 15, ZeroExportController::EXIT_RECOVERY_SOC
    assert_equal 30, ZeroExportController::CHARGE_RESERVE_W
  end
end

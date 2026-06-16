# Pure control law for zero-export: choose the inverter AC setpoint so that
# output never exceeds measured household load (which guarantees no export).
class ZeroExportController
  MAX_OUTPUT_W = 800 # legal balcony-PV feed limit
  MIN_SOC_PCT  = 10  # device discharge floor (enforced by the inverter)

  # Battery-recovery hysteresis. Near the discharge floor the inverter refuses
  # to discharge, so commanding it makes the output toggle. While the SoC is in
  # the recovery band we stop requesting discharge and instead leave a little PV
  # to recharge. The band straddles the observed toggle zone (~12%).
  ENTER_RECOVERY_SOC = 13  # enter recovery at or below this SoC
  EXIT_RECOVERY_SOC  = 15  # leave recovery at or above this SoC
  CHARGE_RESERVE_W   = 30  # PV reserved for charging while in recovery

  # consumption_w is the live measured load, or nil when no fresh sample is
  # available (then we fall back to the export-safe floor). In recovery we cap
  # the setpoint at pv_power_w - CHARGE_RESERVE_W so the battery is never asked
  # to discharge and a few watts of PV trickle back into it.
  def self.target_output_w(consumption_w:, floor_w:, pv_power_w:, recovery:)
    basis = consumption_w.nil? ? floor_w : consumption_w
    basis = [ basis, pv_power_w - CHARGE_RESERVE_W ].min if recovery
    basis.clamp(0, MAX_OUTPUT_W).round
  end
end

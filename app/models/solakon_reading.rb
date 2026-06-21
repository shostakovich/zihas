require "solakon_client"

class SolakonReading < ApplicationRecord
  MIN_SOC_PCT       = 10
  RESUME_SOC_PCT    = 11
  LOW_SOC_PCT       = 20     # display threshold for the "low" battery character (not a safety floor)
  HOT_TEMP_C        = 45.0   # start of our thermal de-rating (full output ceiling); exit PROTECTED below this (no hysteresis)
  COLD_TEMP_C       = 5.0    # display threshold for the "cold" battery character
  CUTOFF_TEMP_C     = 49.0   # de-rating reaches zero: no battery discharge above this (1 °C below the inverter's own 50 °C curtailment)
  CHARGE_DEADBAND_W = 10     # |power| below this reads as idle rather than charging/discharging
  PV_PRESENT_W      = 50
  USABLE_CAPACITY_WH = 1920

  validates :taken_at, :active_power_w, :pv_power_w, :battery_power_w, :battery_soc_pct, presence: true
  validates :active_power_w, :pv_power_w, :battery_power_w, numericality: true
  validates :battery_soc_pct, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :battery_temperature_c, numericality: true, allow_nil: true
  validates :battery_voltage_v, :battery_current_a, :inverter_temperature_c,
            :eps_voltage_v, :eps_power_w,
            numericality: true, allow_nil: true
  validates :status1, :status3, :alarm1, :alarm2, :alarm3,
            numericality: { only_integer: true }, allow_nil: true

  scope :newest_first, -> { order(taken_at: :desc) }

  def self.latest_fresh(stale_after_s:, now: Time.current)
    newest_first.where("taken_at >= ?", now - stale_after_s.to_i.seconds).first
  end

  # The Solakon One reports register 39230 (battery_power_w) with charging as a
  # POSITIVE value (verified live against the device). The UI uses the same sign
  # convention — charging +, discharging − — so the raw value is used as-is.
  def battery_display_power_w
    battery_power_w.to_f
  end

  def soc_below_minimum? = battery_soc_pct <= MIN_SOC_PCT
  def soc_at_resume?     = battery_soc_pct >= RESUME_SOC_PCT
  def battery_hot?       = battery_temperature_c.present? && battery_temperature_c >= HOT_TEMP_C
  def battery_cold?      = battery_temperature_c.present? && battery_temperature_c <= COLD_TEMP_C
  def battery_cooled?    = battery_temperature_c.blank? || battery_temperature_c < HOT_TEMP_C
  def pv_present?        = pv_power_w.to_f >= PV_PRESENT_W

  # Display state for the battery character (asset selection in the UI). Ordered
  # by precedence: a fault always wins, then thermal, then charge level/flow.
  def battery_state
    if [ alarm1, alarm2, alarm3 ].any? { |value| value.to_i.positive? }
      "fault"
    elsif battery_hot?
      "hot"
    elsif battery_cold?
      "cold"
    elsif battery_soc_pct.present? && battery_soc_pct <= LOW_SOC_PCT
      "low"
    elsif battery_display_power_w > CHARGE_DEADBAND_W
      "charging"
    elsif battery_display_power_w < -CHARGE_DEADBAND_W
      "discharging"
    else
      "normal"
    end
  end

  def usable_wh
    [ battery_soc_pct - MIN_SOC_PCT, 0 ].max / 100.0 * USABLE_CAPACITY_WH
  end

  def status_messages
    SolakonClient.decode_status_messages(
      status1: status1,
      status3: status3,
      alarm1: alarm1,
      alarm2: alarm2,
      alarm3: alarm3,
      bms_faults: []
    )
  end
end

class SolakonReading < ApplicationRecord
  MIN_SOC_PCT       = 10
  RESUME_SOC_PCT    = 11
  HOT_TEMP_C        = 42.0
  HOT_RESUME_TEMP_C = 41.8
  PV_PRESENT_W      = 50
  USABLE_CAPACITY_WH = 1920

  validates :taken_at, :active_power_w, :pv_power_w, :battery_power_w, :battery_soc_pct, presence: true
  validates :active_power_w, :pv_power_w, :battery_power_w, numericality: true
  validates :battery_soc_pct, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :battery_temperature_c, numericality: true, allow_nil: true

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
  def battery_cooled?    = battery_temperature_c.blank? || battery_temperature_c <= HOT_RESUME_TEMP_C
  def pv_present?        = pv_power_w.to_f >= PV_PRESENT_W

  def usable_wh
    [ battery_soc_pct - MIN_SOC_PCT, 0 ].max / 100.0 * USABLE_CAPACITY_WH
  end
end

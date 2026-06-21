require "solakon_client"

class SolakonSnapshot < ApplicationRecord
  PANEL_FIELDS = (1..4).flat_map { |idx| [ :"pv#{idx}_power_w", :"pv#{idx}_voltage_v", :"pv#{idx}_current_a" ] }.freeze
  NUMERIC_FIELDS = (PANEL_FIELDS + %i[
    battery_voltage_v battery_current_a battery_power_w battery_temperature_c
    battery_min_temperature_c remaining_energy_wh full_charge_capacity_ah
    design_energy_wh inverter_temperature_c grid_power_w eps_voltage_v eps_power_w
    pv_total_kwh battery_charge_total_kwh battery_discharge_total_kwh
    grid_export_total_kwh grid_import_total_kwh
  ]).freeze
  INTEGER_FIELDS = %i[battery_soc_pct battery_health_pct status1 status3 alarm1 alarm2 alarm3].freeze

  validates :taken_at, presence: true
  validates(*NUMERIC_FIELDS, numericality: true, allow_nil: true)
  validates(*INTEGER_FIELDS, numericality: { only_integer: true }, allow_nil: true)

  scope :newest_first, -> { order(taken_at: :desc) }
  scope :in_range, ->(from:, to:) { where(taken_at: from..to).order(:taken_at) }

  def self.latest = newest_first.first

  def connected_panels
    (1..2).filter_map do |idx|
      power = public_send(:"pv#{idx}_power_w")
      voltage = public_send(:"pv#{idx}_voltage_v")
      current = public_send(:"pv#{idx}_current_a")
      next if [ power, voltage, current ].all? { |value| value.to_f.zero? }

      { index: idx, label: "Panel #{idx}", power_w: power.to_f, voltage_v: voltage.to_f, current_a: current.to_f }
    end
  end

  def status_messages
    SolakonClient.decode_status_messages(
      status1: status1,
      status3: status3,
      alarm1: alarm1,
      alarm2: alarm2,
      alarm3: alarm3,
      bms_faults: bms_faults || []
    )
  end
end

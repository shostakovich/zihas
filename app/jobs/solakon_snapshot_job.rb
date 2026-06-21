require "config_loader"
require "solakon_client"

class SolakonSnapshotJob < ApplicationJob
  queue_as :default

  def perform(client: nil, now: Time.current)
    config = ConfigLoader.app_config
    solakon = config.solakon

    return Rails.logger.info("solakon_snapshot: not configured") if solakon.nil?
    return Rails.logger.info("solakon_snapshot: monitoring disabled") unless solakon.monitoring_enabled

    client ||= SolakonClient.new(host: solakon.host, port: solakon.port, unit_id: solakon.unit_id)
    data = client.read_snapshot

    SolakonSnapshot.create!(snapshot_attributes(data, now))
  rescue SolakonClient::Error => e
    Rails.logger.warn("solakon_snapshot: Modbus failure: #{e.message}")
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("solakon_snapshot: invalid snapshot: #{e.record.errors.full_messages.join(", ")}")
  end

  private

  def snapshot_attributes(data, now)
    attrs = {
      taken_at: now,
      battery_voltage_v: data.battery_voltage_v,
      battery_current_a: data.battery_current_a,
      battery_temperature_c: data.battery_temperature_c,
      battery_min_temperature_c: data.battery_min_temperature_c,
      battery_health_pct: data.battery_health_pct,
      remaining_energy_wh: data.remaining_energy_wh,
      full_charge_capacity_ah: data.full_charge_capacity_ah,
      design_energy_wh: data.design_energy_wh,
      inverter_temperature_c: data.inverter_temperature_c,
      grid_power_w: data.grid_power_w,
      eps_enabled: data.eps_enabled,
      eps_voltage_v: data.eps_voltage_v,
      eps_power_w: data.eps_power_w,
      status1: data.status1,
      status3: data.status3,
      alarm1: data.alarm1,
      alarm2: data.alarm2,
      alarm3: data.alarm3,
      bms_faults: data.bms_faults,
      pv_total_kwh: data.pv_total_kwh,
      battery_charge_total_kwh: data.battery_charge_total_kwh,
      battery_discharge_total_kwh: data.battery_discharge_total_kwh,
      grid_export_total_kwh: data.grid_export_total_kwh,
      grid_import_total_kwh: data.grid_import_total_kwh
    }

    data.panels.each do |panel|
      attrs[:"pv#{panel.index}_power_w"] = panel.power_w
      attrs[:"pv#{panel.index}_voltage_v"] = panel.voltage_v
      attrs[:"pv#{panel.index}_current_a"] = panel.current_a
    end

    attrs
  end
end

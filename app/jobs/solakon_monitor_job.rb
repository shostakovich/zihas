require "config_loader"
require "solakon_client"

class SolakonMonitorJob < ApplicationJob
  queue_as :default

  def perform(client: nil, now: Time.current)
    config = ConfigLoader.app_config
    solakon = config.solakon

    return Rails.logger.info("solakon_monitor: not configured") if solakon.nil?
    return Rails.logger.info("solakon_monitor: disabled") unless solakon.monitoring_enabled

    client ||= SolakonClient.new(host: solakon.host, port: solakon.port, unit_id: solakon.unit_id)
    state = client.read_state

    SolakonReading.create!(
      taken_at: now,
      active_power_w: state.active_power_w,
      pv_power_w: state.pv_power_w,
      battery_power_w: state.battery_power_w,
      battery_soc_pct: state.battery_soc,
      battery_temperature_c: state.battery_temperature_c,
      battery_voltage_v: state.battery_voltage_v,
      battery_current_a: state.battery_current_a,
      inverter_temperature_c: state.inverter_temperature_c,
      status1: state.status1,
      status3: state.status3,
      alarm1: state.alarm1,
      alarm2: state.alarm2,
      alarm3: state.alarm3,
      eps_enabled: state.eps_enabled,
      eps_voltage_v: state.eps_voltage_v,
      eps_power_w: state.eps_power_w
    )

    ZeroExportTickJob.perform_now(state: state) if solakon.control_enabled
    broadcast_dashboard_refresh
  rescue SolakonClient::Error => e
    # A read failure aborts here, so control never runs and no setpoint is
    # written. With no write to re-arm REG_REMOTE_TIMEOUT, the inverter's own
    # 150s remote-control watchdog drops remote control autonomously — that
    # hardware watchdog is the intended backstop for read outages. The tick
    # job's consecutive-failure release_control! covers *write* failures.
    Rails.logger.warn("solakon_monitor: Modbus failure: #{e.message}")
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("solakon_monitor: invalid reading: #{e.record.errors.full_messages.join(", ")}")
  end

  private

  def broadcast_dashboard_refresh
    ActionCable.server.broadcast("dashboard", { solakon: true })
  rescue StandardError => e
    Rails.logger.warn("solakon_monitor: dashboard broadcast failed: #{e.message}")
  end
end

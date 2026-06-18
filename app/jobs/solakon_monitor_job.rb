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
      battery_soc_pct: state.battery_soc
    )

    ActionCable.server.broadcast("dashboard", { solakon: true })
    ZeroExportTickJob.perform_now(state: state) if solakon.control_enabled
  rescue SolakonClient::Error => e
    Rails.logger.warn("solakon_monitor: Modbus failure: #{e.message}")
  end
end

require "config_loader"
require "solakon_client"

class ZeroExportTickJob < ApplicationJob
  queue_as :default

  FLOOR_CACHE_KEY          = "zero_export.floor_w".freeze
  FAILURE_COUNT_CACHE_KEY  = "zero_export.consecutive_failures".freeze
  RECOVERY_CACHE_KEY       = "zero_export.recovery_mode".freeze
  FLOOR_TTL                = 1.hour
  MAX_CONSECUTIVE_FAILURES = 3

  def perform(client: nil, reader_now: Time.now)
    config  = ConfigLoader.app_config
    solakon = config.solakon
    return Rails.logger.info("zero_export: not configured") if solakon.nil?
    return Rails.logger.info("zero_export: disabled")       unless solakon.enabled

    reader = ConsumptionReader.new(plugs: config.plugs, now: reader_now,
                                   stale_after_s: solakon.stale_after_s)
    floor       = Rails.cache.fetch(FLOOR_CACHE_KEY, expires_in: FLOOR_TTL) { reader.guaranteed_floor_w }
    consumption = reader.current_consumption_w

    client ||= SolakonClient.new(host: solakon.host, port: solakon.port, unit_id: solakon.unit_id)

    begin
      # One Modbus connection per tick: read state, decide the setpoint from
      # SoC + PV (recovery hysteresis), then write — all in control_tick!.
      recovery = nil
      target   = nil
      state = client.control_tick!(min_soc: ZeroExportController::MIN_SOC_PCT) do |st|
        recovery = recovery_mode?(st.battery_soc)
        target   = ZeroExportController.target_output_w(
          consumption_w: consumption, floor_w: floor,
          pv_power_w: st.pv_power_w, recovery: recovery
        )
      end
      reset_failures
      consumption_str = consumption.nil? ? "stale" : "#{consumption.round}W"
      Rails.logger.info(
        "zero_export: consumption=#{consumption_str} floor=#{floor.round}W target=#{target}W " \
        "recovery=#{recovery} soc=#{state.battery_soc}% active=#{state.active_power_w}W " \
        "pv=#{state.pv_power_w}W battery=#{state.battery_power_w}W"
      )
    rescue SolakonClient::Error => e
      handle_failure(client, e)
    end
  end

  private

  # Hysteresis: enter the battery-recovery band at/below ENTER_RECOVERY_SOC,
  # leave it at/above EXIT_RECOVERY_SOC, hold the last decision in between.
  def recovery_mode?(soc)
    was = Rails.cache.read(RECOVERY_CACHE_KEY) || false
    now = if soc <= ZeroExportController::ENTER_RECOVERY_SOC
            true
          elsif soc >= ZeroExportController::EXIT_RECOVERY_SOC
            false
          else
            was
          end
    Rails.cache.write(RECOVERY_CACHE_KEY, now)
    now
  end

  def reset_failures
    Rails.cache.write(FAILURE_COUNT_CACHE_KEY, 0)
  end

  def handle_failure(client, error)
    failures = Rails.cache.read(FAILURE_COUNT_CACHE_KEY).to_i + 1
    Rails.cache.write(FAILURE_COUNT_CACHE_KEY, failures)
    Rails.logger.warn(
      "zero_export: Modbus failure #{failures}/#{MAX_CONSECUTIVE_FAILURES}: #{error.message}"
    )
    return if failures < MAX_CONSECUTIVE_FAILURES

    begin
      client.release_control!
      reset_failures
      Rails.logger.warn(
        "zero_export: relinquished remote control after #{failures} consecutive failures " \
        "(inverter reverts to its default mode)"
      )
    rescue SolakonClient::Error => e
      Rails.logger.warn("zero_export: failed to relinquish remote control: #{e.message}")
    end
  end
end

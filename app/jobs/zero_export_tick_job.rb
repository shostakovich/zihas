require "config_loader"
require "solakon_client"

class ZeroExportTickJob < ApplicationJob
  queue_as :default

  HEARTBEAT_S              = 120
  MAX_CONSECUTIVE_FAILURES = 3

  def perform(client: nil, reader_now: Time.current, state: nil)
    config  = ConfigLoader.app_config
    solakon = config.solakon
    return Rails.logger.info("zero_export: not configured") if solakon.nil?
    return Rails.logger.info("zero_export: control disabled") unless solakon.control_enabled
    return Rails.logger.info("zero_export: runtime paused") unless SolakonControlState.current.auto_regulation_active?

    cache = ZeroExportCache.new
    reader = ConsumptionReader.new(plugs: config.plugs, now: reader_now, stale_after_s: solakon.stale_after_s)
    floor  = cache.floor_w(reader)
    median = cache.median_w(reader)
    load = LoadEstimate.new(current_w: reader.current_consumption_w, floor_w: floor,
                            median_w: median)

    client ||= SolakonClient.from_config(solakon)

    begin
      state ||= client.read_state
      reading = reading_from(state, reader_now)

      decision = ZeroExportController.decide(
        reading: reading, load: load,
        previous_state: cache.previous_state
      )

      write_target!(client, decision, reader_now, cache) if should_write?(decision, reader_now, cache)
      cache.remember_state(decision)
      cache.reset_failures
      log(decision, load, reading)
    rescue SolakonClient::Error => e
      handle_failure(client, e, cache)
    end
  end

  private

  def reading_from(state, now)
    SolakonReading.new(taken_at: now, active_power_w: state.active_power_w,
                       pv_power_w: state.pv_power_w, battery_power_w: state.battery_power_w,
                       battery_soc_pct: state.battery_soc, battery_temperature_c: state.battery_temperature_c)
  end

  # Reads like the policy: write on a new state, when the watchdog heartbeat is
  # due, when the target has moved beyond its deadband, or when a protective
  # decision cuts the target to zero. That last case matters because the thermal
  # de-rating can step the ceiling down by less than the deadband right at the
  # cutoff (e.g. ~40W -> 0W as it crosses 48C); waiting for the heartbeat would
  # let the battery keep discharging past the cutoff. The active-power register
  # is volatile, so the extra write is cheap.
  def should_write?(decision, now, cache)
    last = cache.last_write
    return true if last.missing?

    last.state != decision.state ||
      heartbeat_due?(last, now) ||
      decision.differs_from?(last.target_w) ||
      cutoff_to_zero?(decision, last)
  end

  def cutoff_to_zero?(decision, last)
    decision.target_w.zero? && last.target_w.to_i.positive?
  end

  def heartbeat_due?(last, now)
    (now - last.at) >= HEARTBEAT_S
  end

  def write_target!(client, decision, now, cache)
    client.apply_control!(power_w: decision.target_w, min_soc: SolakonReading::MIN_SOC_PCT)
    cache.remember_write(decision, now)
  end

  def log(decision, load, reading)
    current = load.current_w.nil? ? "stale" : "#{load.current_w.round}W"
    Rails.logger.info(
      "zero_export: state=#{decision.state} target=#{decision.target_w}W load=#{current} " \
      "floor=#{load.floor_w.round}W " \
      "soc=#{reading.battery_soc_pct}% temp=#{reading.battery_temperature_c}C pv=#{reading.pv_power_w}W"
    )
  end

  # Reached for *write* failures (the live state is supplied by the monitor, so
  # read failures abort upstream in SolakonMonitorJob, where the inverter's 150s
  # hardware watchdog is the backstop). After repeated write failures we release
  # remote control so the inverter reverts to its own default behavior.
  def handle_failure(client, error, cache)
    failures = cache.increment_failures
    Rails.logger.warn("zero_export: Modbus failure #{failures}/#{MAX_CONSECUTIVE_FAILURES}: #{error.message}")
    return if failures < MAX_CONSECUTIVE_FAILURES

    begin
      client.release_control!
      cache.reset_failures
      Rails.logger.warn("zero_export: relinquished remote control after #{failures} consecutive failures")
    rescue SolakonClient::Error => e
      Rails.logger.warn("zero_export: failed to relinquish remote control: #{e.message}")
    end
  end
end

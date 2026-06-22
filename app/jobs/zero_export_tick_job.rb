require "config_loader"
require "solakon_client"

class ZeroExportTickJob < ApplicationJob
  queue_as :default

  FLOOR_CACHE_KEY         = "zero_export.floor_w".freeze
  MEDIAN_CACHE_KEY        = "zero_export.median_w".freeze
  NIGHT_BASE_CACHE_KEY    = "zero_export.night_base_w".freeze
  STATE_CACHE_KEY         = "zero_export.state".freeze
  LAST_TARGET_CACHE_KEY   = "zero_export.last_target_w".freeze
  LAST_WRITE_AT_CACHE_KEY = "zero_export.last_write_at".freeze
  FAILURE_COUNT_CACHE_KEY = "zero_export.consecutive_failures".freeze

  SLOW_QUERY_TTL           = 1.hour
  MEDIAN_CACHE_TTL         = 60.seconds
  HEARTBEAT_S              = 120
  MAX_CONSECUTIVE_FAILURES = 3

  LastWrite = Struct.new(:state, :target_w, :at, keyword_init: true) do
    def self.from_cache
      at = Rails.cache.read(LAST_WRITE_AT_CACHE_KEY)
      new(state: Rails.cache.read(STATE_CACHE_KEY)&.to_sym,
          target_w: Rails.cache.read(LAST_TARGET_CACHE_KEY), at: at)
    end

    def missing? = at.nil? || target_w.nil?
  end

  def perform(client: nil, reader_now: Time.current, state: nil)
    config  = ConfigLoader.app_config
    solakon = config.solakon
    return Rails.logger.info("zero_export: not configured") if solakon.nil?
    return Rails.logger.info("zero_export: control disabled") unless solakon.control_enabled
    return Rails.logger.info("zero_export: runtime paused") unless SolakonControlState.current.auto_regulation_active?

    reader = ConsumptionReader.new(plugs: config.plugs, now: reader_now, stale_after_s: solakon.stale_after_s)
    floor  = Rails.cache.fetch(FLOOR_CACHE_KEY, expires_in: SLOW_QUERY_TTL) { reader.guaranteed_floor_w }
    median = Rails.cache.fetch(MEDIAN_CACHE_KEY, expires_in: MEDIAN_CACHE_TTL) { reader.median_consumption_w }
    night_base = night_base_w(reader, config, floor)
    load = LoadEstimate.new(current_w: reader.current_consumption_w, floor_w: floor,
                            median_w: median, night_base_w: night_base)

    client ||= SolakonClient.from_config(solakon)

    begin
      state ||= client.read_state
      reading = reading_from(state, reader_now)
      sun = SunWindow.for(now: reader_now, weather: config.weather, timezone: config.timezone)

      decision = ZeroExportController.decide(
        reading: reading, load: load, sun: sun,
        previous_state: Rails.cache.read(STATE_CACHE_KEY)&.to_sym
      )

      write_target!(client, decision, reader_now) if should_write?(decision, reader_now)
      remember(decision)
      reset_failures
      log(decision, load, reading)
    rescue SolakonClient::Error => e
      handle_failure(client, e)
    end
  end

  private

  def night_base_w(reader, config, floor)
    return floor if config.weather.nil?

    Rails.cache.fetch(NIGHT_BASE_CACHE_KEY, expires_in: SLOW_QUERY_TTL) do
      reader.night_base_w(lat: config.weather.lat, lon: config.weather.lon,
                          timezone: config.timezone,
                          days: ConsumptionReader::NIGHT_BASE_DAYS, fallback_w: floor)
    end
  end

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
  def should_write?(decision, now)
    last = LastWrite.from_cache
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

  def write_target!(client, decision, now)
    client.apply_control!(power_w: decision.target_w, min_soc: SolakonReading::MIN_SOC_PCT)
    Rails.cache.write(LAST_TARGET_CACHE_KEY, decision.target_w)
    Rails.cache.write(LAST_WRITE_AT_CACHE_KEY, now)
  end

  def remember(decision)
    Rails.cache.write(STATE_CACHE_KEY, decision.state)
  end

  def log(decision, load, reading)
    current = load.current_w.nil? ? "stale" : "#{load.current_w.round}W"
    Rails.logger.info(
      "zero_export: state=#{decision.state} target=#{decision.target_w}W load=#{current} " \
      "floor=#{load.floor_w.round}W night_base=#{load.night_base_w.round}W " \
      "soc=#{reading.battery_soc_pct}% temp=#{reading.battery_temperature_c}C pv=#{reading.pv_power_w}W"
    )
  end

  def reset_failures
    Rails.cache.write(FAILURE_COUNT_CACHE_KEY, 0)
  end

  # Reached for *write* failures (the live state is supplied by the monitor, so
  # read failures abort upstream in SolakonMonitorJob, where the inverter's 150s
  # hardware watchdog is the backstop). After repeated write failures we release
  # remote control so the inverter reverts to its own default behavior.
  def handle_failure(client, error)
    failures = Rails.cache.read(FAILURE_COUNT_CACHE_KEY).to_i + 1
    Rails.cache.write(FAILURE_COUNT_CACHE_KEY, failures)
    Rails.logger.warn("zero_export: Modbus failure #{failures}/#{MAX_CONSECUTIVE_FAILURES}: #{error.message}")
    return if failures < MAX_CONSECUTIVE_FAILURES

    begin
      client.release_control!
      reset_failures
      Rails.logger.warn("zero_export: relinquished remote control after #{failures} consecutive failures")
    rescue SolakonClient::Error => e
      Rails.logger.warn("zero_export: failed to relinquish remote control: #{e.message}")
    end
  end
end

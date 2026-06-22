class ZeroExportCache
  FLOOR_CACHE_KEY         = "zero_export.floor_w".freeze
  MEDIAN_CACHE_KEY        = "zero_export.median_w".freeze
  NIGHT_BASE_CACHE_KEY    = "zero_export.night_base_w".freeze
  STATE_CACHE_KEY         = "zero_export.state".freeze
  LAST_TARGET_CACHE_KEY   = "zero_export.last_target_w".freeze
  LAST_WRITE_AT_CACHE_KEY = "zero_export.last_write_at".freeze
  FAILURE_COUNT_CACHE_KEY = "zero_export.consecutive_failures".freeze

  SLOW_QUERY_TTL   = 1.hour
  MEDIAN_CACHE_TTL = 60.seconds

  LastWrite = Struct.new(:state, :target_w, :at, keyword_init: true) do
    def missing? = at.nil? || target_w.nil?
  end

  def initialize(cache: Rails.cache)
    @cache = cache
  end

  def floor_w(reader)
    @cache.fetch(FLOOR_CACHE_KEY, expires_in: SLOW_QUERY_TTL) { reader.guaranteed_floor_w }
  end

  def median_w(reader)
    @cache.fetch(MEDIAN_CACHE_KEY, expires_in: MEDIAN_CACHE_TTL) { reader.median_consumption_w }
  end

  def night_base_w(reader, config, floor)
    return floor if config.weather.nil?

    @cache.fetch(NIGHT_BASE_CACHE_KEY, expires_in: SLOW_QUERY_TTL) do
      reader.night_base_w(lat: config.weather.lat, lon: config.weather.lon,
                          timezone: config.timezone,
                          days: ConsumptionReader::NIGHT_BASE_DAYS, fallback_w: floor)
    end
  end

  def previous_state
    @cache.read(STATE_CACHE_KEY)&.to_sym
  end

  def remember_state(decision)
    @cache.write(STATE_CACHE_KEY, decision.state)
  end

  def last_write
    LastWrite.new(
      state: previous_state,
      target_w: @cache.read(LAST_TARGET_CACHE_KEY),
      at: @cache.read(LAST_WRITE_AT_CACHE_KEY)
    )
  end

  def remember_write(decision, now)
    @cache.write(LAST_TARGET_CACHE_KEY, decision.target_w)
    @cache.write(LAST_WRITE_AT_CACHE_KEY, now)
  end

  def reset_failures
    @cache.write(FAILURE_COUNT_CACHE_KEY, 0)
  end

  def increment_failures
    failures = @cache.read(FAILURE_COUNT_CACHE_KEY).to_i + 1
    @cache.write(FAILURE_COUNT_CACHE_KEY, failures)
    failures
  end
end

require "yaml"
require "tzinfo"

class ConfigLoader
  class Error < StandardError; end

  PlugCfg     = Struct.new(:id, :name, :role, :host, keyword_init: true)
  PollCfg     = Struct.new(:interval_seconds, :timeout_seconds,
                           :circuit_breaker_threshold, :circuit_breaker_probe_seconds,
                           keyword_init: true)
  AggCfg      = Struct.new(:run_at, :raw_retention_days, keyword_init: true)
  Config      = Struct.new(:electricity_price_eur_per_kwh, :timezone,
                           :poll, :aggregator, :plugs, keyword_init: true)

  VALID_ROLES = %i[producer consumer].freeze
  ID_REGEX    = /\A[a-z0-9_]+\z/

  def self.load(path)
    raw = YAML.safe_load_file(path)
    raise Error, "config root must be a mapping" unless raw.is_a?(Hash)

    new(raw).build
  end

  def initialize(raw)
    @raw = raw
  end

  def build
    price = require_number(@raw["electricity_price_eur_per_kwh"], "electricity_price_eur_per_kwh", allow_zero: false)
    tz    = require_string(@raw["timezone"], "timezone")
    begin
      TZInfo::Timezone.get(tz)
    rescue TZInfo::InvalidTimezoneIdentifier
      raise Error, "timezone '#{tz}' is not a valid IANA timezone"
    end

    poll       = build_poll(@raw["poll"])
    aggregator = build_aggregator(@raw["aggregator"])
    plugs      = build_plugs(@raw["plugs"])

    Config.new(
      electricity_price_eur_per_kwh: price,
      timezone: tz,
      poll: poll,
      aggregator: aggregator,
      plugs: plugs,
    )
  end

  private

  def build_poll(h)
    h = require_hash(h, "poll")
    PollCfg.new(
      interval_seconds:              require_number(h["interval_seconds"],              "poll.interval_seconds"),
      timeout_seconds:               require_number(h["timeout_seconds"],               "poll.timeout_seconds"),
      circuit_breaker_threshold:     require_number(h["circuit_breaker_threshold"],     "poll.circuit_breaker_threshold").to_i,
      circuit_breaker_probe_seconds: require_number(h["circuit_breaker_probe_seconds"], "poll.circuit_breaker_probe_seconds"),
    )
  end

  def build_aggregator(h)
    h = require_hash(h, "aggregator")
    run_at = require_string(h["run_at"], "aggregator.run_at")
    raise Error, "aggregator.run_at must be HH:MM" unless run_at =~ /\A\d{2}:\d{2}\z/
    AggCfg.new(
      run_at: run_at,
      raw_retention_days: require_number(h["raw_retention_days"], "aggregator.raw_retention_days").to_i,
    )
  end

  def build_plugs(list)
    raise Error, "plugs must be a non-empty list" unless list.is_a?(Array) && !list.empty?

    ids = []
    plugs = list.map.with_index do |h, i|
      raise Error, "plugs[#{i}] must be a mapping" unless h.is_a?(Hash)
      id   = require_string(h["id"], "plugs[#{i}].id")
      raise Error, "plug id '#{id}' must match #{ID_REGEX.source}" unless id =~ ID_REGEX
      raise Error, "duplicate plug id '#{id}'" if ids.include?(id)
      ids << id

      role = require_string(h["role"], "plugs[#{i}].role").to_sym
      raise Error, "plug '#{id}' role must be one of #{VALID_ROLES}" unless VALID_ROLES.include?(role)

      PlugCfg.new(
        id:   id,
        name: require_string(h["name"], "plugs[#{i}].name"),
        role: role,
        host: require_string(h["host"], "plugs[#{i}].host"),
      )
    end

    unless plugs.any? { |p| p.role == :producer }
      raise Error, "config must include at least one plug with role: producer"
    end

    plugs
  end

  def require_hash(v, key)
    raise Error, "#{key} must be a mapping" unless v.is_a?(Hash)
    v
  end

  def require_string(v, key)
    raise Error, "#{key} is required" if v.nil? || v.to_s.empty?
    v.to_s
  end

  def require_number(v, key, allow_zero: false)
    raise Error, "#{key} must be a number" unless v.is_a?(Numeric)
    raise Error, "#{key} must be > 0" if (allow_zero ? v < 0 : v <= 0)
    v
  end
end

require "yaml"
require "tzinfo"

class ConfigLoader
  class Error < StandardError; end

  PlugCfg     = Struct.new(:id, :name, :role, :host, :ain, :driver, keyword_init: true)
  PollCfg     = Struct.new(:interval_seconds, :timeout_seconds,
                           :circuit_breaker_threshold, :circuit_breaker_probe_seconds,
                           keyword_init: true)
  AggCfg      = Struct.new(:run_at, :raw_retention_days, keyword_init: true)
  FritzBoxCfg = Struct.new(:host, :user, :password, keyword_init: true)
  Config      = Struct.new(:electricity_price_eur_per_kwh, :timezone,
                           :poll, :aggregator, :plugs, :fritz_box, keyword_init: true)

  class PlugValidator
    def initialize(h, index, existing_ids)
      @h            = h
      @index        = index
      @existing_ids = existing_ids
    end

    def validate!
      raise ConfigLoader::Error, "plugs[#{@index}] must be a mapping" unless @h.is_a?(Hash)

      id = require_string(@h["id"], "plugs[#{@index}].id")
      raise ConfigLoader::Error, "plug id '#{id}' must match #{ConfigLoader::ID_REGEX.source}" unless id =~ ConfigLoader::ID_REGEX
      raise ConfigLoader::Error, "duplicate plug id '#{id}'" if @existing_ids.include?(id)

      role = require_string(@h["role"], "plugs[#{@index}].role").to_sym
      raise ConfigLoader::Error, "plug '#{id}' role must be one of #{ConfigLoader::VALID_ROLES}" unless ConfigLoader::VALID_ROLES.include?(role)

      driver = (@h["driver"] || "shelly").to_sym
      raise ConfigLoader::Error, "plug '#{id}' driver must be one of #{ConfigLoader::VALID_DRIVERS}" unless ConfigLoader::VALID_DRIVERS.include?(driver)

      name = require_string(@h["name"], "plugs[#{@index}].name")
      build_plug(id, name, role, driver)
    end

    private

    def build_plug(id, name, role, driver)
      if driver == :shelly
        raise ConfigLoader::Error, "plugs[#{@index}].host is required for driver: shelly" if @h["host"].nil? || @h["host"].to_s.empty?
        raise ConfigLoader::Error, "plugs[#{@index}].ain must not be set for driver: shelly" if @h["ain"]
        ConfigLoader::PlugCfg.new(id: id, name: name, role: role, driver: :shelly, host: @h["host"].to_s, ain: nil)
      else
        raise ConfigLoader::Error, "plugs[#{@index}].ain is required for driver: fritz_dect" if @h["ain"].nil? || @h["ain"].to_s.empty?
        raise ConfigLoader::Error, "plugs[#{@index}].host must not be set for driver: fritz_dect" if @h["host"]
        ConfigLoader::PlugCfg.new(id: id, name: name, role: role, driver: :fritz_dect, ain: @h["ain"].to_s, host: nil)
      end
    end

    def require_string(v, key)
      raise ConfigLoader::Error, "#{key} is required" if v.nil? || v.to_s.empty?
      v.to_s
    end
  end

  VALID_ROLES   = %i[producer consumer].freeze
  VALID_DRIVERS = %i[shelly fritz_dect].freeze
  ID_REGEX      = /\A[a-z0-9_]+\z/

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
    fritz_box  = build_fritz_box(@raw["fritz_box"])
    plugs      = build_plugs(@raw["plugs"])

    if plugs.any? { |p| p.driver == :fritz_dect } && fritz_box.nil?
      raise Error, "fritz_box config required when using driver: fritz_dect"
    end

    Config.new(
      electricity_price_eur_per_kwh: price,
      timezone: tz,
      poll: poll,
      aggregator: aggregator,
      plugs: plugs,
      fritz_box: fritz_box,
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

  def build_fritz_box(h)
    return nil if h.nil?
    h = require_hash(h, "fritz_box")
    FritzBoxCfg.new(
      host:     require_string(h["host"],     "fritz_box.host"),
      user:     require_string(h["user"],     "fritz_box.user"),
      password: require_string(h["password"], "fritz_box.password"),
    )
  end

  def build_plugs(list)
    raise Error, "plugs must be a non-empty list" unless list.is_a?(Array) && !list.empty?

    ids   = []
    plugs = list.map.with_index do |h, i|
      plug = PlugValidator.new(h, i, ids).validate!
      ids << plug.id
      plug
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

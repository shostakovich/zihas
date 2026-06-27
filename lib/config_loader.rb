require "yaml"
require "tzinfo"

class ConfigLoader
  class Error < StandardError; end

  PlugCfg     = Struct.new(:id, :name, :role, :ain, :driver, :room, :switchable, keyword_init: true)
  MqttCfg     = Struct.new(:host, :port, :topic_prefix, keyword_init: true)
  FritzPollCfg = Struct.new(:active_interval_seconds, :idle_interval_seconds,
                             :idle_threshold_w, :timeout_seconds, keyword_init: true)
  FritzBoxCfg = Struct.new(:host, :user, :password, keyword_init: true)
  WeatherCfg   = Struct.new(:lat, :lon, keyword_init: true)
  SwitchbotCfg = Struct.new(:token, :secret, keyword_init: true)
  SensorCfg    = Struct.new(:id, :name, :type, :room, keyword_init: true)
  TrmnlCfg     = Struct.new(:energy_webhook_url, :sensors_webhook_url, keyword_init: true)
  SolakonCfg   = Struct.new(:host, :port, :unit_id, :monitoring_enabled, :control_enabled,
                              :stale_after_s, keyword_init: true)
  GoveeCfg     = Struct.new(:api_key, :lan_poll_seconds, :api_poll_seconds,
                            :pending_window_seconds, :names, keyword_init: true)
  Config       = Struct.new(:electricity_price_eur_per_kwh, :timezone,
                            :mqtt, :fritz_poll, :plugs, :fritz_box, :weather,
                            :switchbot, :sensors, :trmnl, :solakon, :govee,
                            keyword_init: true)

  module StringRequirement
    private

    def require_string(v, key)
      raise ConfigLoader::Error, "#{key} is required" if v.nil? || v.to_s.empty?
      v.to_s
    end
  end

  class PlugValidator
    include ConfigLoader::StringRequirement

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

      switchable = @h.key?("switchable") ? @h["switchable"] : false
      unless [ true, false ].include?(switchable)
        raise ConfigLoader::Error, "plugs[#{@index}].switchable must be true or false"
      end
      if switchable && role == :producer
        raise ConfigLoader::Error, "plug '#{id}' with role: producer cannot be switchable"
      end

      build_plug(id, name, role, driver, switchable)
    end

    private

    def build_plug(id, name, role, driver, switchable)
      room = @h["room"].nil? ? nil : require_string(@h["room"], "plugs[#{@index}].room")
      if driver == :shelly
        raise ConfigLoader::Error, "plugs[#{@index}].ain must not be set for driver: shelly" if @h["ain"]
        ConfigLoader::PlugCfg.new(id: id, name: name, role: role, driver: :shelly, ain: nil, room: room, switchable: switchable)
      else
        raise ConfigLoader::Error, "plugs[#{@index}].ain is required for driver: fritz_dect" if @h["ain"].nil? || @h["ain"].to_s.empty?
        ConfigLoader::PlugCfg.new(id: id, name: name, role: role, driver: :fritz_dect, ain: @h["ain"].to_s, room: room, switchable: switchable)
      end
    end
  end

  VALID_ROLES        = %i[producer consumer].freeze
  VALID_DRIVERS      = %i[shelly fritz_dect].freeze
  VALID_SENSOR_TYPES = %i[meter_pro_co2 outdoor_meter].freeze
  ID_REGEX      = /\A[a-z0-9_]+\z/

  def self.load(path)
    raw = YAML.safe_load_file(path)
    raise Error, "config root must be a mapping" unless raw.is_a?(Hash)

    new(raw).build
  rescue Errno::ENOENT
    raise Error, "config file not found"
  end

  APP_CONFIG_MUTEX = Mutex.new

  def self.app_config
    @app_config || APP_CONFIG_MUTEX.synchronize do
      @app_config ||= load(default_path)
    end
  end

  def self.reset_app_config!
    APP_CONFIG_MUTEX.synchronize { @app_config = nil }
  end

  def self.default_path
    Rails.root.join("config", Rails.env.test? ? "ziwoas.test.yml" : "ziwoas.yml").to_s
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

    mqtt       = build_mqtt(@raw["mqtt"])
    fritz_poll = build_fritz_poll(@raw["fritz_poll"])
    fritz_box  = build_fritz_box(@raw["fritz_box"])
    plugs      = build_plugs(@raw["plugs"])
    weather    = build_weather(@raw["weather"])
    switchbot  = build_switchbot(@raw["switchbot"])
    sensors    = build_sensors(@raw["sensors"])
    trmnl      = build_trmnl(@raw["trmnl"])
    solakon    = build_solakon(@raw["solakon"])
    govee      = build_govee(@raw["govee"])

    if plugs.any? { |p| p.driver == :fritz_dect } && fritz_box.nil?
      raise Error, "fritz_box config required when using driver: fritz_dect"
    end

    if plugs.any? { |p| p.driver == :fritz_dect } && fritz_poll.nil?
      raise Error, "fritz_poll config required when using driver: fritz_dect"
    end

    Config.new(
      electricity_price_eur_per_kwh: price,
      timezone:   tz,
      mqtt:       mqtt,
      fritz_poll: fritz_poll,
      plugs:      plugs,
      fritz_box:  fritz_box,
      weather:    weather,
      switchbot:  switchbot,
      sensors:    sensors,
      trmnl:      trmnl,
      solakon:    solakon,
      govee:      govee,
    )
  end

  private

  def build_mqtt(h)
    raise Error, "mqtt config is required" if h.nil?
    h = require_hash(h, "mqtt")
    MqttCfg.new(
      host:         require_string(h["host"],  "mqtt.host"),
      port:         require_number(h["port"].to_i, "mqtt.port").to_i,
      topic_prefix: require_string(h["topic_prefix"], "mqtt.topic_prefix"),
    )
  end

  def build_fritz_poll(h)
    return nil if h.nil?
    h = require_hash(h, "fritz_poll")
    FritzPollCfg.new(
      active_interval_seconds: require_number(h["active_interval_seconds"], "fritz_poll.active_interval_seconds"),
      idle_interval_seconds:   require_number(h["idle_interval_seconds"],   "fritz_poll.idle_interval_seconds"),
      idle_threshold_w:        require_number(h["idle_threshold_w"].to_f,   "fritz_poll.idle_threshold_w", allow_zero: true),
      timeout_seconds:         require_number(h["timeout_seconds"],         "fritz_poll.timeout_seconds"),
    )
  end

  def build_fritz_box(h)
    return nil if h.nil?
    h = require_hash(h, "fritz_box")
    host, user, password = %w[host user password].map { |k| require_string(h[k], "fritz_box.#{k}") }
    FritzBoxCfg.new(host: host, user: user, password: password)
  end

  def build_weather(h)
    return nil if h.nil?
    h = require_hash(h, "weather")
    lat = require_coordinate(h["lat"], "weather.lat")
    lon = require_coordinate(h["lon"], "weather.lon")
    raise Error, "weather.lat must be between -90 and 90" unless (-90..90).cover?(lat)
    raise Error, "weather.lon must be between -180 and 180" unless (-180..180).cover?(lon)

    WeatherCfg.new(lat: lat, lon: lon)
  end

  def build_switchbot(h)
    return nil if h.nil?
    h = require_hash(h, "switchbot")
    SwitchbotCfg.new(
      token:  require_string(h["token"],  "switchbot.token"),
      secret: require_string(h["secret"], "switchbot.secret"),
    )
  end

  def build_sensors(list)
    return [] if list.nil?
    raise Error, "sensors must be a list" unless list.is_a?(Array)

    seen = []
    list.map.with_index do |h, i|
      raise Error, "sensors[#{i}] must be a mapping" unless h.is_a?(Hash)
      id   = require_string(h["id"],   "sensors[#{i}].id")
      name = require_string(h["name"], "sensors[#{i}].name")
      type = require_string(h["type"], "sensors[#{i}].type").to_sym
      raise Error, "sensors[#{i}].type must be one of #{VALID_SENSOR_TYPES}" unless VALID_SENSOR_TYPES.include?(type)
      raise Error, "duplicate sensor id '#{id}'" if seen.include?(id)
      seen << id
      room = h["room"].nil? ? nil : require_string(h["room"], "sensors[#{i}].room")
      SensorCfg.new(id: id, name: name, type: type, room: room)
    end
  end

  ALLOWED_TRMNL_KEYS = %w[energy_webhook_url sensors_webhook_url].freeze

  def build_trmnl(h)
    return TrmnlCfg.new(energy_webhook_url: nil, sensors_webhook_url: nil) if h.nil?
    h = require_hash(h, "trmnl")
    unknown = h.keys - ALLOWED_TRMNL_KEYS
    raise Error, "trmnl unknown keys: #{unknown.join(', ')}" if unknown.any?

    TrmnlCfg.new(
      energy_webhook_url:  require_optional_string(h["energy_webhook_url"],  "trmnl.energy_webhook_url"),
      sensors_webhook_url: require_optional_string(h["sensors_webhook_url"], "trmnl.sensors_webhook_url"),
    )
  end

  def build_solakon(h)
    return nil if h.nil?
    h = require_hash(h, "solakon")

    # `enabled` is the legacy spelling of `monitoring_enabled`; honour it for
    # backward compatibility until configs are migrated.
    monitoring_enabled = solakon_boolean(h, "monitoring_enabled", legacy: "enabled", default: true)
    control_enabled    = solakon_boolean(h, "control_enabled", default: false)

    SolakonCfg.new(
      host:               require_string(h["host"], "solakon.host"),
      port:               (h["port"] || 502).to_i,
      unit_id:            (h["unit_id"] || 1).to_i,
      monitoring_enabled: monitoring_enabled,
      control_enabled:    control_enabled,
      stale_after_s:      (h["stale_after_s"] || 120).to_i,
    )
  end

  def solakon_boolean(h, key, default:, legacy: nil)
    return require_boolean(h[key], "solakon.#{key}") if h.key?(key)
    return require_boolean(h[legacy], "solakon.#{legacy}") if legacy && h.key?(legacy)
    default
  end

  def require_boolean(v, key)
    return v if [ true, false ].include?(v)

    raise Error, "#{key} must be true or false"
  end

  def require_optional_string(v, key)
    return nil if v.nil?
    raise Error, "#{key} must be a string" unless v.is_a?(String)
    v
  end

  def require_coordinate(v, key)
    raise Error, "#{key} must be a number" if v.nil? || v.to_s.empty?
    Float(v)
  rescue ArgumentError, TypeError
    raise Error, "#{key} must be a number"
  end

  def build_plugs(list)
    raise Error, "plugs must be a list" unless list.is_a?(Array)
    return [] if list.empty?

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

  def build_govee(h)
    return nil if h.nil?
    h = require_hash(h, "govee")
    names = Array(h["devices"]).each_with_object({}) do |d, acc|
      key = require_string(d["key"], "govee.devices[].key")
      acc[key] = { name: d["name"].to_s, room: d["room"] }
    end
    GoveeCfg.new(
      # Secret lives in the gitignored ziwoas.yml (like fritz_box.password).
      api_key:                h["api_key"].to_s,
      lan_poll_seconds:       (h["lan_poll_seconds"] || 8).to_i,
      api_poll_seconds:       (h["api_poll_seconds"] || 180).to_i,
      pending_window_seconds: (h["pending_window_seconds"] || 5).to_i,
      names:                  names,
    )
  end

  include StringRequirement

  def require_hash(v, key)
    raise Error, "#{key} must be a mapping" unless v.is_a?(Hash)
    v
  end

  def require_number(v, key, allow_zero: false)
    raise Error, "#{key} must be a number" unless v.is_a?(Numeric)
    raise Error, "#{key} must be > 0" if allow_zero ? v < 0 : v <= 0
    v
  end
end

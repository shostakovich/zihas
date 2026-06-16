require "test_helper"
require "config_loader"
require "tempfile"

class ConfigLoaderTest < Minitest::Test
  def load_yaml(yaml)
    file = Tempfile.new([ "config", ".yml" ])
    file.write(yaml); file.flush
    ConfigLoader.load(file.path)
  ensure
    file&.close
    file&.unlink
  end

  def valid_yaml
    <<~YAML
      electricity_price_eur_per_kwh: 0.32
      timezone: Europe/Berlin
      mqtt:
        host: 192.168.1.103
        port: 1883
        topic_prefix: shellies
      plugs:
        - id: bkw
          name: Balkonkraftwerk
          role: producer
        - id: fridge
          name: Kühlschrank
          role: consumer
    YAML
  end

  def valid_yaml_with_fritz
    valid_yaml + <<~YAML
      fritz_box:
        host: 192.168.178.1
        user: fritz6584
        password: secret
      fritz_poll:
        active_interval_seconds: 5
        idle_interval_seconds: 60
        idle_threshold_w: 10
        timeout_seconds: 2
    YAML
  end

  def test_loads_valid_config
    cfg = load_yaml(valid_yaml)
    assert_in_delta 0.32, cfg.electricity_price_eur_per_kwh
    assert_equal "Europe/Berlin", cfg.timezone
    assert_equal 2, cfg.plugs.length
    assert_equal "bkw", cfg.plugs.first.id
    assert_equal :producer, cfg.plugs.first.role
  end

  def test_ignores_legacy_aggregator_config
    cfg = load_yaml(valid_yaml + <<~YAML)
      aggregator:
        run_at: "03:15"
        raw_retention_days: 99
    YAML

    assert_respond_to cfg, :plugs
    assert_equal false, cfg.respond_to?(:aggregator)
  end

  def test_loads_mqtt_config
    cfg = load_yaml(valid_yaml)
    assert_equal "192.168.1.103", cfg.mqtt.host
    assert_equal 1883, cfg.mqtt.port
    assert_equal "shellies", cfg.mqtt.topic_prefix
  end

  def test_loads_fritz_poll_config
    cfg = load_yaml(valid_yaml_with_fritz)
    assert_equal 5,    cfg.fritz_poll.active_interval_seconds
    assert_equal 60,   cfg.fritz_poll.idle_interval_seconds
    assert_equal 10,   cfg.fritz_poll.idle_threshold_w
    assert_equal 2,    cfg.fritz_poll.timeout_seconds
  end

  def test_shelly_plug_has_no_host
    cfg = load_yaml(valid_yaml)
    plug = cfg.plugs.find { |p| p.id == "bkw" }
    assert_equal false, plug.respond_to?(:host)
  end

  def test_fritz_poll_required_when_fritz_dect_plug_present
    yaml_with_fritz_plug = valid_yaml + <<~EXTRA
      fritz_box:
        host: 192.168.178.1
        user: fritz6584
        password: secret
      plugs:
        - id: bkw
          name: BKW
          role: producer
        - id: waschmaschine
          name: Waschmaschine
          role: consumer
          driver: fritz_dect
          ain: "08761 0500475"
    EXTRA
    err = assert_raises(ConfigLoader::Error) { load_yaml(yaml_with_fritz_plug) }
    assert_match(/fritz_poll/i, err.message)
  end

  def test_mqtt_required
    yaml = valid_yaml.sub(/mqtt:.*topic_prefix: shellies\n/m, "")
    err = assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
    assert_match(/mqtt/i, err.message)
  end

  def test_rejects_duplicate_plug_ids
    yaml = valid_yaml.sub("id: fridge", "id: bkw")
    err = assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
    assert_match(/duplicate plug id/i, err.message)
  end

  def test_rejects_missing_producer
    yaml = valid_yaml.sub("role: producer", "role: consumer")
    err = assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
    assert_match(/at least one.*producer/i, err.message)
  end

  def test_rejects_invalid_timezone
    yaml = valid_yaml.sub("Europe/Berlin", "Not/ATimezone")
    err = assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
    assert_match(/timezone/i, err.message)
  end

  def test_rejects_fritz_dect_plug_without_ain
    yaml = valid_yaml_with_fritz + <<~EXTRA
      plugs:
        - id: bkw
          name: BKW
          role: producer
        - id: ws
          name: WS
          role: consumer
          driver: fritz_dect
    EXTRA
    err = assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
    assert_match(/ain.*required/i, err.message)
  end

  def test_loads_optional_weather_config
    cfg = load_yaml(valid_yaml + <<~YAML)
      weather:
        lat: 52.52
        lon: 13.405
    YAML

    assert_in_delta 52.52, cfg.weather.lat
    assert_in_delta 13.405, cfg.weather.lon
  end

  def test_weather_config_is_optional
    cfg = load_yaml(valid_yaml)

    assert_nil cfg.weather
  end

  def test_rejects_invalid_weather_latitude
    err = assert_raises(ConfigLoader::Error) do
      load_yaml(valid_yaml + <<~YAML)
        weather:
          lat: 100
          lon: 13.405
      YAML
    end

    assert_match(/weather\.lat/i, err.message)
  end

  def test_rejects_invalid_weather_longitude
    err = assert_raises(ConfigLoader::Error) do
      load_yaml(valid_yaml + <<~YAML)
        weather:
          lat: 52.52
          lon: 200
      YAML
    end

    assert_match(/weather\.lon/i, err.message)
  end

  def test_rejects_missing_weather_latitude
    err = assert_raises(ConfigLoader::Error) do
      load_yaml(valid_yaml + <<~YAML)
        weather:
          lon: 13.405
      YAML
    end

    assert_match(/weather\.lat/i, err.message)
  end

  def test_rejects_non_numeric_weather_longitude
    err = assert_raises(ConfigLoader::Error) do
      load_yaml(valid_yaml + <<~YAML)
        weather:
          lat: 52.52
          lon: east
      YAML
    end

    assert_match(/weather\.lon/i, err.message)
  end

  def test_loads_optional_plug_room
    yaml = valid_yaml.sub("name: Balkonkraftwerk\n    role: producer",
                          "name: Balkonkraftwerk\n    role: producer\n    room: Balkon")
    cfg = load_yaml(yaml)
    plug = cfg.plugs.find { |p| p.id == "bkw" }
    assert_equal "Balkon", plug.room
  end

  def test_plug_room_is_optional_and_defaults_to_nil
    cfg = load_yaml(valid_yaml)
    plug = cfg.plugs.find { |p| p.id == "fridge" }
    assert_nil plug.room
  end

  def test_loads_switchbot_and_sensors
    cfg = load_yaml(valid_yaml + <<~YAML)
      switchbot:
        token: "tok-abc"
        secret: "sec-xyz"
      sensors:
        - id: "ABCDEF"
          name: "Wohnzimmer"
          type: meter_pro_co2
          room: "Wohnzimmer"
        - id: "FEDCBA"
          name: "Schlafzimmer"
          type: meter_pro_co2
        - id: "112233"
          name: "Balkon"
          type: outdoor_meter
    YAML

    assert_equal "tok-abc", cfg.switchbot.token
    assert_equal "sec-xyz", cfg.switchbot.secret

    assert_equal 3, cfg.sensors.length
    s = cfg.sensors.first
    assert_equal "ABCDEF", s.id
    assert_equal "Wohnzimmer", s.name
    assert_equal :meter_pro_co2, s.type
    assert_equal "Wohnzimmer", s.room

    assert_nil cfg.sensors[1].room
    assert_equal :outdoor_meter, cfg.sensors[2].type
  end

  def test_switchbot_and_sensors_are_optional
    cfg = load_yaml(valid_yaml)
    assert_nil cfg.switchbot
    assert_equal [], cfg.sensors
  end

  def test_rejects_switchbot_missing_token
    err = assert_raises(ConfigLoader::Error) do
      load_yaml(valid_yaml + <<~YAML)
        switchbot:
          secret: "sec-only"
      YAML
    end
    assert_match(/switchbot\.token/i, err.message)
  end

  def test_rejects_unknown_sensor_type
    err = assert_raises(ConfigLoader::Error) do
      load_yaml(valid_yaml + <<~YAML)
        switchbot:
          token: "t"
          secret: "s"
        sensors:
          - id: "X"
            name: "X"
            type: foo_meter
      YAML
    end
    assert_match(/sensors\[0\]\.type/i, err.message)
  end

  def test_rejects_duplicate_sensor_ids
    err = assert_raises(ConfigLoader::Error) do
      load_yaml(valid_yaml + <<~YAML)
        switchbot:
          token: "t"
          secret: "s"
        sensors:
          - id: "DUP"
            name: "A"
            type: meter_pro_co2
          - id: "DUP"
            name: "B"
            type: meter_pro_co2
      YAML
    end
    assert_match(/duplicate sensor id/i, err.message)
  end

  def test_loads_trmnl_block_with_both_urls
    yaml = valid_yaml + <<~YAML
      trmnl:
        energy_webhook_url: https://trmnl.com/api/custom_plugins/energy-uuid
        sensors_webhook_url: https://trmnl.com/api/custom_plugins/sensor-uuid
    YAML
    cfg = load_yaml(yaml)
    assert_equal "https://trmnl.com/api/custom_plugins/energy-uuid",  cfg.trmnl.energy_webhook_url
    assert_equal "https://trmnl.com/api/custom_plugins/sensor-uuid", cfg.trmnl.sensors_webhook_url
  end

  def test_trmnl_block_defaults_to_nil_urls_when_block_absent
    cfg = load_yaml(valid_yaml)
    refute_nil cfg.trmnl
    assert_nil cfg.trmnl.energy_webhook_url
    assert_nil cfg.trmnl.sensors_webhook_url
  end

  def test_trmnl_block_accepts_partial_configuration
    yaml = valid_yaml + <<~YAML
      trmnl:
        sensors_webhook_url: https://trmnl.com/api/custom_plugins/only-sensors
    YAML
    cfg = load_yaml(yaml)
    assert_nil cfg.trmnl.energy_webhook_url
    assert_equal "https://trmnl.com/api/custom_plugins/only-sensors", cfg.trmnl.sensors_webhook_url
  end

  def test_rejects_non_string_trmnl_url
    yaml = valid_yaml + <<~YAML
      trmnl:
        energy_webhook_url: 42
    YAML
    assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
  end

  def test_rejects_unknown_keys_inside_trmnl_block
    yaml = valid_yaml + <<~YAML
      trmnl:
        bogus: yes
    YAML
    err = assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
    assert_match(/trmnl/i, err.message)
  end

  def test_plug_switchable_defaults_to_false
    cfg = load_yaml(valid_yaml)
    assert_equal false, cfg.plugs.last.switchable
  end

  def test_plug_switchable_true_is_parsed
    yaml = valid_yaml.sub("role: consumer", "role: consumer\n    switchable: true")
    cfg = load_yaml(yaml)
    assert_equal true, cfg.plugs.last.switchable
    assert_equal false, cfg.plugs.first.switchable
  end

  def test_plug_switchable_must_be_boolean
    yaml = valid_yaml.sub("role: consumer", "role: consumer\n    switchable: yes please")
    e = assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
    assert_match(/switchable must be true or false/, e.message)
  end

  def test_switchable_producer_raises
    yaml = valid_yaml.sub("role: producer", "role: producer\n    switchable: true")
    e = assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
    assert_match(/producer.*switchable|switchable.*producer/i, e.message)
  end

  def test_load_raises_config_error_for_missing_file
    error = assert_raises(ConfigLoader::Error) do
      ConfigLoader.load("/nonexistent/path/ziwoas.yml")
    end
    assert_match(/config file not found/i, error.message)
  end

  def test_app_config_memoizes_and_resets
    ConfigLoader.reset_app_config!
    first  = ConfigLoader.app_config
    second = ConfigLoader.app_config
    assert_same first, second

    ConfigLoader.reset_app_config!
    refute_same first, ConfigLoader.app_config
  end

  def valid_yaml_with_solakon
    valid_yaml + <<~YAML
      solakon:
        host: 192.168.1.50
        port: 502
        unit_id: 1
        enabled: true
        stale_after_s: 90
    YAML
  end

  def test_solakon_is_nil_when_absent
    assert_nil load_yaml(valid_yaml).solakon
  end

  def test_solakon_parses_full_block
    sol = load_yaml(valid_yaml_with_solakon).solakon
    assert_equal "192.168.1.50", sol.host
    assert_equal 502, sol.port
    assert_equal 1, sol.unit_id
    assert_equal true, sol.enabled
    assert_equal 90, sol.stale_after_s
  end

  def test_solakon_applies_defaults
    yaml = valid_yaml + <<~YAML
      solakon:
        host: 10.0.0.9
    YAML
    sol = load_yaml(yaml).solakon
    assert_equal 502, sol.port
    assert_equal 1, sol.unit_id
    assert_equal true, sol.enabled
    assert_equal 120, sol.stale_after_s
  end

  def test_solakon_requires_host
    yaml = valid_yaml + "solakon:\n  port: 502\n"
    assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
  end
end

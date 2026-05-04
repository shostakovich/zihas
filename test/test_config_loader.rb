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
end

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
      poll:
        interval_seconds: 5
        timeout_seconds: 2
        circuit_breaker_threshold: 3
        circuit_breaker_probe_seconds: 30
      aggregator:
        run_at: "03:15"
        raw_retention_days: 7
      plugs:
        - id: bkw
          name: Balkonkraftwerk
          role: producer
          host: 192.168.1.192
        - id: fridge
          name: Kühlschrank
          role: consumer
          host: 192.168.1.201
    YAML
  end

  def test_loads_valid_config
    cfg = load_yaml(valid_yaml)
    assert_in_delta 0.32, cfg.electricity_price_eur_per_kwh
    assert_equal "Europe/Berlin", cfg.timezone
    assert_equal 5, cfg.poll.interval_seconds
    assert_equal "03:15", cfg.aggregator.run_at
    assert_equal 2, cfg.plugs.length
    assert_equal "bkw", cfg.plugs.first.id
    assert_equal :producer, cfg.plugs.first.role
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

  def test_rejects_invalid_role
    yaml = valid_yaml.sub("role: producer", "role: foo")
    err = assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
    assert_match(/role/i, err.message)
  end

  def test_rejects_invalid_id_chars
    yaml = valid_yaml.sub("id: bkw", "id: BKW-1")
    err = assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
    assert_match(/plug id/i, err.message)
  end

  def test_rejects_unknown_timezone
    yaml = valid_yaml.sub("Europe/Berlin", "Europe/Narnia")
    err = assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
    assert_match(/timezone/i, err.message)
  end

  def test_rejects_nonpositive_numbers
    yaml = valid_yaml.sub("interval_seconds: 5", "interval_seconds: 0")
    err = assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
    assert_match(/interval_seconds/, err.message)
  end

  def valid_fritz_yaml
    <<~YAML
      electricity_price_eur_per_kwh: 0.32
      timezone: Europe/Berlin
      poll:
        interval_seconds: 5
        timeout_seconds: 2
        circuit_breaker_threshold: 3
        circuit_breaker_probe_seconds: 30
      aggregator:
        run_at: "03:15"
        raw_retention_days: 7
      fritz_box:
        host: 192.168.178.1
        user: fritz6584
        password: secret
      plugs:
        - id: krabbencomputer
          name: Krabbencomputer
          role: producer
          driver: fritz_dect
          ain: "11630 0206224"
    YAML
  end

  def test_shelly_driver_defaults_to_shelly
    cfg = load_yaml(valid_yaml)
    assert_equal :shelly, cfg.plugs.first.driver
    assert_equal "192.168.1.192", cfg.plugs.first.host
    assert_nil cfg.plugs.first.ain
  end

  def test_loads_fritz_dect_plug
    cfg = load_yaml(valid_fritz_yaml)
    plug = cfg.plugs.first
    assert_equal :fritz_dect, plug.driver
    assert_equal "11630 0206224", plug.ain
    assert_nil plug.host
    assert_equal "192.168.178.1", cfg.fritz_box.host
    assert_equal "fritz6584", cfg.fritz_box.user
    assert_equal "secret", cfg.fritz_box.password
  end

  def test_rejects_fritz_dect_without_fritz_box_section
    yaml = valid_fritz_yaml.sub(/^fritz_box:\n(  .*\n){3}/, "")
    err = assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
    assert_match(/fritz_box.*required/i, err.message)
  end

  def test_rejects_fritz_dect_plug_with_host_field
    yaml = valid_fritz_yaml.sub("ain: \"11630 0206224\"",
                                 "ain: \"11630 0206224\"\n    host: 192.168.1.1")
    err = assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
    assert_match(/host.*must not be set/i, err.message)
  end

  def test_rejects_shelly_plug_without_host
    yaml = valid_yaml.sub("    host: 192.168.1.192\n", "")
    err = assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
    assert_match(/host.*required/i, err.message)
  end

  def test_rejects_invalid_driver
    yaml = valid_yaml.sub("    host: 192.168.1.192",
                           "    host: 192.168.1.192\n    driver: zigbee")
    err = assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
    assert_match(/driver/i, err.message)
  end
end

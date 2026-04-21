require "test_helper"
require "config_loader"
require "tempfile"

class ConfigLoaderTest < Minitest::Test
  def load_yaml(yaml)
    file = Tempfile.new(["config", ".yml"])
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
end

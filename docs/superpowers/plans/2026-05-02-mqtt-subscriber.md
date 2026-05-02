# MQTT Subscriber Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace HTTP polling for Shelly plugs with MQTT subscriptions, bridge Fritz!DECT via MQTT, and move all data ingestion into a standalone `bin/ziwoas_collector` process separate from Rails.

**Architecture:** `MqttSubscriber` subscribes to `shellies/+/status/switch:0` and writes Samples directly. `FritzMqttBridge` polls Fritz!DECT adaptively and publishes in the same MQTT format so that one code path handles all devices. Both run in `bin/ziwoas_collector` — Rails stays pure (API + Dashboard only).

**Tech Stack:** Ruby `mqtt` gem, Minitest, ActionCable (Solid Cable adapter for cross-process broadcast), SQLite3 WAL mode.

---

## File Map

| Path | Action | Purpose |
|---|---|---|
| `Gemfile` | Modify | Add `mqtt` gem |
| `lib/config_loader.rb` | Modify | Remove `PollCfg`, add `MqttCfg` + `FritzPollCfg`, remove `host` from Shelly plugs |
| `config/ziwoas.yml` | Modify | Replace `poll:` with `mqtt:` + `fritz_poll:`, drop `host` from Shelly plugs |
| `config/ziwoas.example.yml` | Modify | Same structure update |
| `config/initializers/ziwoas.rb` | Delete | Collector process handles background work |
| `lib/mqtt_subscriber.rb` | Create | MQTT subscribe → Sample insert + ActionCable broadcast |
| `lib/fritz_mqtt_bridge.rb` | Create | Fritz!DECT poll → MQTT publish |
| `bin/ziwoas_collector` | Create | Entry point: starts subscriber + bridge + scheduler |
| `Procfile.dev` | Create | `web` + `worker` for local development |
| `bin/dev` | Modify | Use foreman with Procfile.dev |
| `docker-compose.yml` | Modify | Add `ziwoas_collector` service |
| `Dockerfile` | Modify | Remove now-unnecessary `SKIP_BACKGROUND` |
| `config/application.rb` | Modify | Remove unused `attr_accessor :ziwoas_app` |
| `lib/ziwoas.rb` | Delete | Replaced by `bin/ziwoas_collector` bootstrap |
| `lib/shelly_client.rb` | Delete | HTTP polling replaced by MQTT |
| `lib/poller.rb` | Delete | Replaced by `MqttSubscriber` |
| `lib/circuit_breaker.rb` | Delete | No longer needed |
| `test/test_mqtt_subscriber.rb` | Create | Unit tests for MqttSubscriber |
| `test/test_fritz_mqtt_bridge.rb` | Create | Unit tests for FritzMqttBridge |
| `test/test_config_loader.rb` | Modify | Update for new config shape |
| `test/test_poller.rb` | Delete | Poller is removed |
| `test/test_shelly_client.rb` | Delete | ShellyClient is removed |
| `test/test_circuit_breaker.rb` | Delete | CircuitBreaker is removed |

---

## Task 1: Add mqtt gem

**Files:**
- Modify: `Gemfile`

- [ ] **Step 1: Add gem to Gemfile**

In `Gemfile`, after the `gem "rexml"` line add:

```ruby
gem "mqtt"
```

- [ ] **Step 2: Install**

```bash
bundle install
```

Expected: `mqtt` gem installed, `Gemfile.lock` updated.

- [ ] **Step 3: Commit**

```bash
git add Gemfile Gemfile.lock
git commit -m "feat: add mqtt gem"
```

---

## Task 2: Update ConfigLoader and config files

**Files:**
- Modify: `lib/config_loader.rb`
- Modify: `config/ziwoas.yml`
- Modify: `config/ziwoas.example.yml`
- Delete: `config/initializers/ziwoas.rb`
- Modify: `test/test_config_loader.rb`
- Modify: `test/test_poller.rb` (remove `host:` from PlugCfg calls)

- [ ] **Step 1: Write a failing test for the new config shape**

Replace the entire content of `test/test_config_loader.rb` with:

```ruby
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
      mqtt:
        host: 192.168.1.103
        port: 1883
        topic_prefix: shellies
      aggregator:
        run_at: "03:15"
        raw_retention_days: 7
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
    assert_equal "03:15", cfg.aggregator.run_at
    assert_equal 2, cfg.plugs.length
    assert_equal "bkw", cfg.plugs.first.id
    assert_equal :producer, cfg.plugs.first.role
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
    assert_nil plug.respond_to?(:host) ? plug.host : nil
  end

  def test_fritz_poll_required_when_fritz_dect_plug_present
    yaml = valid_yaml_with_fritz.sub(/fritz_poll:.*\z/m, "")
    # remove fritz_poll section but keep fritz_box and fritz_dect plug
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
```

- [ ] **Step 2: Run to confirm tests fail**

```bash
bundle exec rails test test/test_config_loader.rb
```

Expected: multiple failures (`NoMethodError` or `ArgumentError` on `mqtt`, `fritz_poll`).

- [ ] **Step 3: Update ConfigLoader**

Replace the entire content of `lib/config_loader.rb` with:

```ruby
require "yaml"
require "tzinfo"

class ConfigLoader
  class Error < StandardError; end

  PlugCfg     = Struct.new(:id, :name, :role, :ain, :driver, keyword_init: true)
  MqttCfg     = Struct.new(:host, :port, :topic_prefix, keyword_init: true)
  FritzPollCfg = Struct.new(:active_interval_seconds, :idle_interval_seconds,
                             :idle_threshold_w, :timeout_seconds, keyword_init: true)
  AggCfg      = Struct.new(:run_at, :raw_retention_days, keyword_init: true)
  FritzBoxCfg = Struct.new(:host, :user, :password, keyword_init: true)
  Config      = Struct.new(:electricity_price_eur_per_kwh, :timezone,
                           :mqtt, :fritz_poll, :aggregator, :plugs, :fritz_box,
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
      build_plug(id, name, role, driver)
    end

    private

    def build_plug(id, name, role, driver)
      if driver == :shelly
        raise ConfigLoader::Error, "plugs[#{@index}].ain must not be set for driver: shelly" if @h["ain"]
        ConfigLoader::PlugCfg.new(id: id, name: name, role: role, driver: :shelly, ain: nil)
      else
        raise ConfigLoader::Error, "plugs[#{@index}].ain is required for driver: fritz_dect" if @h["ain"].nil? || @h["ain"].to_s.empty?
        ConfigLoader::PlugCfg.new(id: id, name: name, role: role, driver: :fritz_dect, ain: @h["ain"].to_s)
      end
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

    mqtt       = build_mqtt(@raw["mqtt"])
    fritz_poll = build_fritz_poll(@raw["fritz_poll"])
    aggregator = build_aggregator(@raw["aggregator"])
    fritz_box  = build_fritz_box(@raw["fritz_box"])
    plugs      = build_plugs(@raw["plugs"])

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
      aggregator: aggregator,
      plugs:      plugs,
      fritz_box:  fritz_box,
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
    host, user, password = %w[host user password].map { |k| require_string(h[k], "fritz_box.#{k}") }
    FritzBoxCfg.new(host: host, user: user, password: password)
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
```

- [ ] **Step 4: Run config loader tests**

```bash
bundle exec rails test test/test_config_loader.rb
```

Expected: all pass.

- [ ] **Step 5: Update config/ziwoas.yml**

Replace the content with:

```yaml
electricity_price_eur_per_kwh: 0.2902
timezone: Europe/Berlin

fritz_box:
  host: 192.168.178.1
  user: fritz6584
  password: wowido79

mqtt:
  host: 192.168.1.103
  port: 1883
  topic_prefix: shellies

fritz_poll:
  active_interval_seconds: 5
  idle_interval_seconds: 60
  idle_threshold_w: 10
  timeout_seconds: 2

aggregator:
  run_at: "03:15"
  raw_retention_days: 7

plugs:
  - id: bkw
    name: Solar
    role: producer

  - id: robbe
    name: Robbe
    role: consumer

  - id: krabbe
    name: Krabbe
    role: consumer

  - id: robbebike
    name: Waschmaschine
    role: consumer
    driver: fritz_dect
    ain: "08761 0500475"

  - id: fridge
    name: Kühlschrank
    role: consumer

  - id: dishwasher
    name: Spülmaschine
    role: consumer

  - id: readingcorner
    name: Leseecke
    role: consumer
```

- [ ] **Step 6: Update config/ziwoas.example.yml**

Replace the content with:

```yaml
# Copy to config/ziwoas.yml and edit to your setup.
electricity_price_eur_per_kwh: 0.32
timezone: Europe/Berlin

mqtt:
  host: 192.168.1.103    # MQTT broker IP
  port: 1883
  topic_prefix: shellies  # Must match the prefix configured on each Shelly device

aggregator:
  run_at: "03:15"
  raw_retention_days: 7

# Required when any plug uses driver: fritz_dect.
# Each Shelly device must be configured (Web UI → Settings → MQTT) with
# Topic prefix: shellies/<plug_id>  (e.g. shellies/bkw, shellies/fridge)
#
# fritz_box:
#   host: 192.168.178.1
#   user: fritz6584        # Fritz!Box username
#   password: secret       # Fritz!Box password
#
# fritz_poll:              # Required when fritz_dect driver is used
#   active_interval_seconds: 5
#   idle_interval_seconds: 60
#   idle_threshold_w: 10   # Below this wattage: use idle interval
#   timeout_seconds: 2

plugs:
  - id: bkw
    name: Balkonkraftwerk
    role: producer
    # Shelly MQTT prefix must be: shellies/bkw

  # Shelly consumer example:
  # - id: kuehlschrank
  #   name: Kühlschrank
  #   role: consumer
  #   # Shelly MQTT prefix must be: shellies/kuehlschrank

  # Fritz!DECT consumer example (AIN from Fritz!Box device list):
  # - id: waschmaschine
  #   name: Waschmaschine
  #   role: consumer
  #   driver: fritz_dect
  #   ain: "11630 0206224"
```

- [ ] **Step 7: Update test/test_poller.rb to remove `host:` from PlugCfg**

In `test/test_poller.rb`, replace both occurrences of `PlugCfg.new(...)` that include `host:`:

```ruby
# Replace this:
ConfigLoader::PlugCfg.new(id: "bkw",    name: "BKW",   role: :producer, driver: :shelly, host: "10.0.0.1", ain: nil)
ConfigLoader::PlugCfg.new(id: "fridge",  name: "Fridge", role: :consumer, driver: :shelly, host: "10.0.0.2", ain: nil)

# With this:
ConfigLoader::PlugCfg.new(id: "bkw",    name: "BKW",   role: :producer, driver: :shelly, ain: nil)
ConfigLoader::PlugCfg.new(id: "fridge",  name: "Fridge", role: :consumer, driver: :shelly, ain: nil)
```

- [ ] **Step 8: Delete the Rails initializer**

```bash
rm config/initializers/ziwoas.rb
```

- [ ] **Step 9: Run the full test suite**

```bash
bundle exec rails test
```

Expected: all pass (poller tests still pass because `lib/poller.rb` still exists).

- [ ] **Step 10: Commit**

```bash
git add lib/config_loader.rb config/ziwoas.yml config/ziwoas.example.yml \
        test/test_config_loader.rb test/test_poller.rb
git rm config/initializers/ziwoas.rb
git commit -m "feat: update config for MQTT — add mqtt/fritz_poll sections, remove poll section and host from Shelly plugs"
```

---

## Task 3: Write MqttSubscriber

**Files:**
- Create: `lib/mqtt_subscriber.rb`
- Create: `test/test_mqtt_subscriber.rb`

- [ ] **Step 1: Write the failing tests**

Create `test/test_mqtt_subscriber.rb`:

```ruby
require "test_helper"
require "mqtt_subscriber"
require "config_loader"
require "logger"
require "stringio"

class MqttSubscriberTest < ActiveSupport::TestCase
  setup do
    Sample.delete_all
    @log_io = StringIO.new
    @logger = Logger.new(@log_io)
    @now    = 1_700_000_000.0

    @mqtt_config = ConfigLoader::MqttCfg.new(
      host: "localhost", port: 1883, topic_prefix: "shellies"
    )
    @plugs = [
      ConfigLoader::PlugCfg.new(id: "bkw",   name: "Solar",  role: :producer, driver: :shelly, ain: nil),
      ConfigLoader::PlugCfg.new(id: "fridge", name: "Fridge", role: :consumer, driver: :shelly, ain: nil),
    ]
    @subscriber = MqttSubscriber.new(
      mqtt_config: @mqtt_config,
      plugs:       @plugs,
      logger:      @logger,
      clock:       -> { @now },
    )
  end

  def status_payload(apower:, total:)
    JSON.generate({ "apower" => apower, "aenergy" => { "total" => total } })
  end

  def capture_broadcasts
    broadcasts = []
    server = ActionCable.server
    original = server.method(:broadcast)
    server.define_singleton_method(:broadcast) { |stream, payload| broadcasts << [stream, payload] }
    yield broadcasts
  ensure
    server.define_singleton_method(:broadcast, original)
  end

  test "handle_message inserts sample for known plug" do
    @subscriber.handle_message("shellies/bkw/status/switch:0",
                               status_payload(apower: 300.0, total: 1234.5))
    assert_equal 1, Sample.count
    s = Sample.first
    assert_equal "bkw", s.plug_id
    assert_equal @now.to_i, s.ts
    assert_in_delta 300.0, s.apower_w
    assert_in_delta 1234.5, s.aenergy_wh
  end

  test "handle_message warns and skips unknown plug" do
    @subscriber.handle_message("shellies/unknown/status/switch:0",
                               status_payload(apower: 1.0, total: 1.0))
    assert_equal 0, Sample.count
    assert_match(/unknown plug.*unknown/i, @log_io.string)
  end

  test "handle_message ignores invalid JSON" do
    assert_nothing_raised do
      @subscriber.handle_message("shellies/bkw/status/switch:0", "not-json{")
    end
    assert_equal 0, Sample.count
    assert_match(/invalid json/i, @log_io.string)
  end

  test "handle_message handles duplicate ts gracefully" do
    Sample.create!(plug_id: "bkw", ts: @now.to_i, apower_w: 1.0, aenergy_wh: 1.0)
    assert_nothing_raised do
      @subscriber.handle_message("shellies/bkw/status/switch:0",
                                 status_payload(apower: 300.0, total: 1234.5))
    end
    assert_equal 1, Sample.where(plug_id: "bkw").count
  end

  test "handle_message broadcasts on power change" do
    capture_broadcasts do |broadcasts|
      @subscriber.handle_message("shellies/bkw/status/switch:0",
                                 status_payload(apower: 300.0, total: 1234.5))
      assert_equal 1, broadcasts.length
      stream, payload = broadcasts.first
      assert_equal "dashboard", stream
      plugs = payload[:plugs]
      assert_equal 1, plugs.length
      assert_equal "bkw",   plugs.first[:plug_id]
      assert_equal "Solar", plugs.first[:name]
      assert_equal "producer", plugs.first[:role]
      assert_in_delta 300.0, plugs.first[:apower_w]
    end
  end

  test "handle_message does not broadcast when rounded power is unchanged" do
    capture_broadcasts do |broadcasts|
      @subscriber.handle_message("shellies/bkw/status/switch:0",
                                 status_payload(apower: 300.0, total: 1234.5))
      Sample.delete_all
      @subscriber.handle_message("shellies/bkw/status/switch:0",
                                 status_payload(apower: 300.4, total: 1234.6))
      assert_equal 1, broadcasts.length
    end
  end

  test "handle_message broadcasts when rounded power changes" do
    capture_broadcasts do |broadcasts|
      @subscriber.handle_message("shellies/bkw/status/switch:0",
                                 status_payload(apower: 300.0, total: 1234.5))
      Sample.delete_all
      @now += 1
      @subscriber.handle_message("shellies/bkw/status/switch:0",
                                 status_payload(apower: 350.0, total: 1234.6))
      assert_equal 2, broadcasts.length
    end
  end

  test "producer apower_w is compared as absolute value for broadcast threshold" do
    capture_broadcasts do |broadcasts|
      @subscriber.handle_message("shellies/bkw/status/switch:0",
                                 status_payload(apower: -300.0, total: 1234.5))
      Sample.delete_all
      @now += 1
      @subscriber.handle_message("shellies/bkw/status/switch:0",
                                 status_payload(apower: -300.4, total: 1234.6))
      assert_equal 1, broadcasts.length
    end
  end
end
```

- [ ] **Step 2: Run to confirm tests fail**

```bash
bundle exec rails test test/test_mqtt_subscriber.rb
```

Expected: `LoadError: cannot load such file -- mqtt_subscriber`

- [ ] **Step 3: Create lib/mqtt_subscriber.rb**

```ruby
require "mqtt"
require "json"

class MqttSubscriber
  def initialize(mqtt_config:, plugs:, logger:, clock: -> { Time.now.to_f })
    @mqtt_config  = mqtt_config
    @plug_map     = plugs.to_h { |p| [p.id, p] }
    @logger       = logger
    @clock        = clock
    @stopping     = false
    @buckets      = {}
    @last_power_w = {}
  end

  def run
    backoff = 1
    until @stopping
      connect_and_run
      backoff = 1
    rescue => e
      @logger.error("MqttSubscriber: #{e.class}: #{e.message}")
      sleep([backoff, 60].min) unless @stopping
      backoff = [backoff * 2, 60].min
    end
  end

  def stop!
    @stopping = true
    @client&.disconnect rescue nil
  end

  def handle_message(topic, payload)
    plug_id = topic.split("/")[1]
    plug    = @plug_map[plug_id]
    unless plug
      @logger.warn("MqttSubscriber: unknown plug '#{plug_id}' on topic #{topic}")
      return
    end

    data       = JSON.parse(payload)
    apower_w   = data["apower"].to_f
    aenergy_wh = data.dig("aenergy", "total").to_f
    ts         = @clock.call.to_i

    Sample.create!(plug_id: plug_id, ts: ts, apower_w: apower_w, aenergy_wh: aenergy_wh)
    broadcast_if_changed(plug, ts, apower_w, aenergy_wh)
  rescue ActiveRecord::RecordNotUnique
    # duplicate ts within same second — skip silently
  rescue JSON::ParserError => e
    @logger.warn("MqttSubscriber: invalid JSON on #{topic}: #{e.message}")
  end

  private

  def connect_and_run
    @client = MQTT::Client.new(host: @mqtt_config.host, port: @mqtt_config.port)
    @client.connect
    topic = "#{@mqtt_config.topic_prefix}/+/status/switch:0"
    @client.subscribe(topic)
    @logger.info("MqttSubscriber: connected to #{@mqtt_config.host}:#{@mqtt_config.port}, subscribed #{topic}")
    @client.get { |t, payload| handle_message(t, payload) }
  ensure
    @client&.disconnect rescue nil
  end

  def broadcast_if_changed(plug, ts, apower_w, aenergy_wh)
    display_power = (plug.role == :producer ? apower_w.abs : apower_w).round
    return if @last_power_w[plug.id] == display_power

    @last_power_w[plug.id] = display_power

    bucket_ts = (ts / 60) * 60
    bucket    = @buckets[plug.id]
    if bucket && bucket[:bucket_ts] == bucket_ts
      bucket[:sum]   += apower_w
      bucket[:count] += 1
    else
      @buckets[plug.id] = { bucket_ts: bucket_ts, sum: apower_w, count: 1 }
      bucket = @buckets[plug.id]
    end
    avg_power_w = bucket[:sum].to_f / bucket[:count]

    ActionCable.server.broadcast("dashboard", {
      ts:    ts,
      plugs: [{
        plug_id:     plug.id,
        name:        plug.name,
        role:        plug.role.to_s,
        online:      true,
        ts:          ts,
        bucket_ts:   bucket_ts,
        apower_w:    apower_w,
        avg_power_w: avg_power_w,
        aenergy_wh:  aenergy_wh,
      }]
    })
  rescue => e
    @logger.warn("MqttSubscriber: ActionCable broadcast failed: #{e.message}")
  end
end
```

- [ ] **Step 4: Run tests**

```bash
bundle exec rails test test/test_mqtt_subscriber.rb
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/mqtt_subscriber.rb test/test_mqtt_subscriber.rb
git commit -m "feat: add MqttSubscriber"
```

---

## Task 4: Write FritzMqttBridge

**Files:**
- Create: `lib/fritz_mqtt_bridge.rb`
- Create: `test/test_fritz_mqtt_bridge.rb`

- [ ] **Step 1: Write failing tests**

Create `test/test_fritz_mqtt_bridge.rb`:

```ruby
require "test_helper"
require "fritz_mqtt_bridge"
require "fritz_dect_client"
require "config_loader"
require "logger"
require "stringio"

class FritzMqttBridgeTest < ActiveSupport::TestCase
  setup do
    @log_io = StringIO.new
    @logger = Logger.new(@log_io)

    @plug = ConfigLoader::PlugCfg.new(
      id: "robbebike", name: "Waschmaschine",
      role: :consumer, driver: :fritz_dect, ain: "08761 0500475"
    )
    @mqtt_config = ConfigLoader::MqttCfg.new(
      host: "localhost", port: 1883, topic_prefix: "shellies"
    )
    @fritz_poll_cfg = ConfigLoader::FritzPollCfg.new(
      active_interval_seconds: 5,
      idle_interval_seconds:   60,
      idle_threshold_w:        10,
      timeout_seconds:         2,
    )
  end

  def fake_fritz_client(apower_w:, aenergy_wh:)
    client = Object.new
    client.define_singleton_method(:fetch) do |_plug|
      FritzDectClient::Reading.new(apower_w: apower_w, aenergy_wh: aenergy_wh)
    end
    client
  end

  def fake_mqtt_client
    published = []
    client = Object.new
    client.define_singleton_method(:connect) {}
    client.define_singleton_method(:disconnect) {}
    client.define_singleton_method(:publish) { |topic, payload| published << [topic, payload] }
    client.define_singleton_method(:published) { published }
    client
  end

  def build_bridge(fritz_client:, mqtt_client: nil)
    mqtt_client ||= fake_mqtt_client
    FritzMqttBridge.new(
      fritz_client:     fritz_client,
      plug:             @plug,
      mqtt_config:      @mqtt_config,
      fritz_poll_cfg:   @fritz_poll_cfg,
      logger:           @logger,
      mqtt_factory:     -> { mqtt_client },
    )
  end

  test "poll_and_publish sends correct topic" do
    fritz = fake_fritz_client(apower_w: 42.5, aenergy_wh: 100.0)
    mqtt  = fake_mqtt_client
    bridge = build_bridge(fritz_client: fritz, mqtt_client: mqtt)

    bridge.poll_and_publish(mqtt)

    assert_equal 1, mqtt.published.length
    assert_equal "shellies/robbebike/status/switch:0", mqtt.published.first[0]
  end

  test "poll_and_publish sends correct JSON payload" do
    fritz = fake_fritz_client(apower_w: 42.5, aenergy_wh: 100.0)
    mqtt  = fake_mqtt_client
    bridge = build_bridge(fritz_client: fritz, mqtt_client: mqtt)

    bridge.poll_and_publish(mqtt)

    data = JSON.parse(mqtt.published.first[1])
    assert_in_delta 42.5,  data["apower"]
    assert_in_delta 100.0, data.dig("aenergy", "total")
  end

  test "interval is active when power above threshold" do
    fritz = fake_fritz_client(apower_w: 50.0, aenergy_wh: 1.0)
    mqtt  = fake_mqtt_client
    bridge = build_bridge(fritz_client: fritz, mqtt_client: mqtt)

    bridge.poll_and_publish(mqtt)

    assert_equal 5, bridge.interval
  end

  test "interval is idle when power at or below threshold" do
    fritz = fake_fritz_client(apower_w: 2.0, aenergy_wh: 1.0)
    mqtt  = fake_mqtt_client
    bridge = build_bridge(fritz_client: fritz, mqtt_client: mqtt)

    bridge.poll_and_publish(mqtt)

    assert_equal 60, bridge.interval
  end

  test "interval starts as idle before first poll" do
    fritz = fake_fritz_client(apower_w: 0.0, aenergy_wh: 0.0)
    bridge = build_bridge(fritz_client: fritz)

    assert_equal 60, bridge.interval
  end

  test "poll_and_publish logs warning on fritz error and does not publish" do
    erroring = Object.new
    erroring.define_singleton_method(:fetch) { |_| raise FritzDectClient::Error, "timeout" }
    mqtt   = fake_mqtt_client
    bridge = build_bridge(fritz_client: erroring, mqtt_client: mqtt)

    bridge.poll_and_publish(mqtt)

    assert_equal 0, mqtt.published.length
    assert_match(/timeout/i, @log_io.string)
  end
end
```

- [ ] **Step 2: Run to confirm tests fail**

```bash
bundle exec rails test test/test_fritz_mqtt_bridge.rb
```

Expected: `LoadError: cannot load such file -- fritz_mqtt_bridge`

- [ ] **Step 3: Create lib/fritz_mqtt_bridge.rb**

```ruby
require "mqtt"
require "json"
require "fritz_dect_client"

class FritzMqttBridge
  def initialize(fritz_client:, plug:, mqtt_config:, fritz_poll_cfg:, logger:,
                 mqtt_factory: nil)
    @fritz_client  = fritz_client
    @plug          = plug
    @mqtt_config   = mqtt_config
    @fritz_poll_cfg = fritz_poll_cfg
    @logger        = logger
    @stopping      = false
    @last_apower_w = 0.0
    @mqtt_factory  = mqtt_factory || -> {
      MQTT::Client.new(host: @mqtt_config.host, port: @mqtt_config.port)
    }
  end

  def run
    mqtt = @mqtt_factory.call
    mqtt.connect
    until @stopping
      poll_and_publish(mqtt)
      sleep_interruptible(interval)
    end
  ensure
    mqtt&.disconnect rescue nil
  end

  def stop!
    @stopping = true
  end

  def poll_and_publish(mqtt)
    reading = @fritz_client.fetch(@plug)
    @last_apower_w = reading.apower_w
    payload = JSON.generate({ apower: reading.apower_w, aenergy: { total: reading.aenergy_wh } })
    mqtt.publish("#{@mqtt_config.topic_prefix}/#{@plug.id}/status/switch:0", payload)
  rescue FritzDectClient::Error => e
    @logger.warn("FritzMqttBridge #{@plug.id}: #{e.message}")
  end

  def interval
    @last_apower_w > @fritz_poll_cfg.idle_threshold_w ?
      @fritz_poll_cfg.active_interval_seconds :
      @fritz_poll_cfg.idle_interval_seconds
  end

  private

  def sleep_interruptible(seconds)
    deadline = Time.now + seconds
    while Time.now < deadline && !@stopping
      sleep([deadline - Time.now, 1].min)
    end
  end
end
```

- [ ] **Step 4: Run tests**

```bash
bundle exec rails test test/test_fritz_mqtt_bridge.rb
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/fritz_mqtt_bridge.rb test/test_fritz_mqtt_bridge.rb
git commit -m "feat: add FritzMqttBridge"
```

---

## Task 5: Write bin/ziwoas_collector

**Files:**
- Create: `bin/ziwoas_collector`

- [ ] **Step 1: Create the script**

Create `bin/ziwoas_collector` with this content:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../config/environment"
require "mqtt_subscriber"
require "fritz_mqtt_bridge"
require "aggregator"
require "ziwoas/scheduler"
require "ziwoas/signal_handler"
require "config_loader"
require "fritz_dect_client"
require "tzinfo"

logger = Logger.new($stdout)
logger.level = Logger::INFO

config_path = Rails.root.join("config", "ziwoas.yml").to_s
config      = ConfigLoader.load(config_path)
tz          = TZInfo::Timezone.get(config.timezone)

fritz_plugs  = config.plugs.select { |p| p.driver == :fritz_dect }
shelly_plugs = config.plugs.reject { |p| p.driver == :fritz_dect }

threads    = []
stoppables = []

subscriber = MqttSubscriber.new(
  mqtt_config: config.mqtt,
  plugs:       shelly_plugs,
  logger:      logger,
)
stoppables << subscriber
threads << Thread.new {
  Thread.current.name = "mqtt_subscriber"
  subscriber.run
}

if fritz_plugs.any?
  fritz_client = FritzDectClient.new(
    host:     config.fritz_box.host,
    user:     config.fritz_box.user,
    password: config.fritz_box.password,
    timeout:  config.fritz_poll.timeout_seconds,
  )
  fritz_plugs.each do |plug|
    bridge = FritzMqttBridge.new(
      fritz_client:   fritz_client,
      plug:           plug,
      mqtt_config:    config.mqtt,
      fritz_poll_cfg: config.fritz_poll,
      logger:         logger,
    )
    stoppables << bridge
    threads << Thread.new {
      Thread.current.name = "fritz_bridge_#{plug.id}"
      bridge.run
    }
  end
end

aggregator = Aggregator.new(
  timezone:           tz,
  raw_retention_days: config.aggregator.raw_retention_days,
)
scheduler = Ziwoas::Scheduler.new(
  aggregator: aggregator,
  run_at:     config.aggregator.run_at,
  timezone:   tz,
  logger:     logger,
  backup_dir: Rails.root.join("storage", "backup").to_s,
)
stoppables << scheduler
threads << Thread.new {
  Thread.current.name = "scheduler"
  scheduler.run
}

%w[INT TERM].each do |sig|
  Signal.trap(sig) { stoppables.each(&:stop!) }
end

logger.info("ziwoas_collector: started #{threads.length} threads")
threads.each { |t| t.join(10) }
logger.info("ziwoas_collector: stopped")
```

- [ ] **Step 2: Make executable**

```bash
chmod +x bin/ziwoas_collector
```

- [ ] **Step 3: Smoke test (requires running MQTT broker at 192.168.1.103:1883)**

```bash
RAILS_ENV=development bundle exec ruby bin/ziwoas_collector
```

Expected: logs show `connected to 192.168.1.103:1883, subscribed shellies/+/status/switch:0` and `started 3 threads` (or more if fritz plugs present). Press Ctrl+C to stop — logs show `stopped`.

If the MQTT broker is unreachable, the subscriber will log an error and retry with backoff. That is expected behaviour.

- [ ] **Step 4: Commit**

```bash
git add bin/ziwoas_collector
git commit -m "feat: add bin/ziwoas_collector entry point"
```

---

## Task 6: Add Procfile.dev and update bin/dev

**Files:**
- Create: `Procfile.dev`
- Modify: `bin/dev`

- [ ] **Step 1: Create Procfile.dev**

Create `Procfile.dev` with:

```
web:    ./bin/rails server
worker: ./bin/ziwoas_collector
```

- [ ] **Step 2: Update bin/dev**

Replace the entire content of `bin/dev` with:

```sh
#!/usr/bin/env sh
exec foreman start --procfile Procfile.dev "$@"
```

- [ ] **Step 3: Make executable**

```bash
chmod +x bin/dev
```

- [ ] **Step 4: Test locally**

```bash
bin/dev
```

Expected: foreman starts two processes with `web | ` and `worker | ` prefixes. Ctrl+C stops both.

- [ ] **Step 5: Commit**

```bash
git add Procfile.dev bin/dev
git commit -m "feat: add Procfile.dev and update bin/dev to use foreman"
```

---

## Task 7: Delete old files and clean up

**Files:**
- Delete: `lib/shelly_client.rb`, `lib/poller.rb`, `lib/circuit_breaker.rb`, `lib/ziwoas.rb`
- Delete: `test/test_shelly_client.rb`, `test/test_poller.rb`, `test/test_circuit_breaker.rb`
- Modify: `config/application.rb` (remove `attr_accessor :ziwoas_app`)

- [ ] **Step 1: Delete obsolete lib files**

```bash
rm lib/shelly_client.rb lib/poller.rb lib/circuit_breaker.rb lib/ziwoas.rb
```

- [ ] **Step 2: Delete obsolete test files**

```bash
rm test/test_shelly_client.rb test/test_poller.rb test/test_circuit_breaker.rb
```

- [ ] **Step 3: Remove unused accessor from application.rb**

In `config/application.rb`, remove this line (it was only used by the deleted initializer):

```ruby
attr_accessor :ziwoas_app
```

- [ ] **Step 4: Run full test suite**

```bash
bundle exec rails test
```

Expected: all tests pass, no references to deleted files.

- [ ] **Step 5: Commit**

```bash
git rm lib/shelly_client.rb lib/poller.rb lib/circuit_breaker.rb lib/ziwoas.rb
git rm test/test_shelly_client.rb test/test_poller.rb test/test_circuit_breaker.rb
git add config/application.rb
git commit -m "chore: remove HTTP polling — ShellyClient, Poller, CircuitBreaker replaced by MqttSubscriber"
```

---

## Task 8: Update Docker Compose and Dockerfile

**Files:**
- Modify: `docker-compose.yml`
- Modify: `Dockerfile`

- [ ] **Step 1: Update docker-compose.yml**

Replace the entire content of `docker-compose.yml` with:

```yaml
services:
  ziwoas:
    build: .
    image: ziwoas:latest
    container_name: ziwoas
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      TZ: Europe/Berlin
      SECRET_KEY_BASE: dummy_secret_for_local_docker
    volumes:
      - ./storage:/rails/storage
      - ./config/ziwoas.yml:/rails/config/ziwoas.yml:ro

  ziwoas_collector:
    image: ziwoas:latest
    container_name: ziwoas_collector
    restart: unless-stopped
    command: ["./bin/ziwoas_collector"]
    environment:
      TZ: Europe/Berlin
      SECRET_KEY_BASE: dummy_secret_for_local_docker
    volumes:
      - ./storage:/rails/storage
      - ./config/ziwoas.yml:/rails/config/ziwoas.yml:ro
    depends_on:
      - ziwoas
```

- [ ] **Step 2: Remove SKIP_BACKGROUND from Dockerfile**

In `Dockerfile`, find the asset precompile step:

```dockerfile
RUN SECRET_KEY_BASE_DUMMY=1 SKIP_BACKGROUND=1 \
    DATABASE_URL="sqlite3:///tmp/build.db" \
    ./bin/rails db:schema:load assets:precompile && \
    rm -f /tmp/build.db
```

Replace with (no more `SKIP_BACKGROUND` needed since the initializer is gone):

```dockerfile
RUN SECRET_KEY_BASE_DUMMY=1 \
    DATABASE_URL="sqlite3:///tmp/build.db" \
    ./bin/rails db:schema:load assets:precompile && \
    rm -f /tmp/build.db
```

- [ ] **Step 3: Run full test suite one last time**

```bash
bundle exec rails test
```

Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml Dockerfile
git commit -m "feat: add ziwoas_collector Docker service, remove SKIP_BACKGROUND from Dockerfile"
```

---

## Shelly Device Configuration (Manual Step)

For each Shelly plug, configure via its Web UI (Settings → MQTT):

| Plug | MQTT Topic Prefix to set |
|---|---|
| Solar (bkw) | `shellies/bkw` |
| Robbe | `shellies/robbe` |
| Krabbe | `shellies/krabbe` |
| Kühlschrank (fridge) | `shellies/fridge` |
| Spülmaschine (dishwasher) | `shellies/dishwasher` |
| Leseecke (readingcorner) | `shellies/readingcorner` |

Broker: `192.168.1.103`, Port: `1883`. After saving, verify with:

```bash
mosquitto_sub -h 192.168.1.103 -p 1883 -t "shellies/bkw/status/switch:0" -v
```

Expected: JSON messages appear every few seconds.

# ZiWoAS Shelly-Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first ZiWoAS feature: a Shelly-based monitoring dashboard that shows Balkonkraftwerk yield, per-consumer power draw, today's savings, and a daily-yield history.

**Architecture:** One Ruby process with three threads (poller, aggregator, Sinatra/Puma web server) sharing a local SQLite database. Runs in a single Docker container. Frontend is server-rendered ERB + vendored HTMX (for live polling) + vendored Chart.js (for graphs) — no build step, no npm.

**Tech Stack:** Ruby 4.0.x, Sinatra, Sequel, SQLite, Puma, Minitest, WebMock, Rack::Test, HTMX (vendored), Chart.js (vendored).

**Spec:** `docs/superpowers/specs/2026-04-13-shelly-monitoring-design.md`

---

## File Structure

```
zihas/
├── Dockerfile                       # Task 14 — production image
├── docker-compose.yml               # Task 14 — local + mini-rack deployment
├── Gemfile                          # Task 1
├── Gemfile.lock                     # Task 1 — committed for reproducibility
├── Rakefile                         # Task 1 — runs tests
├── config.ru                        # Task 10 — Rack entrypoint
├── README.md                        # Task 14
├── config/
│   └── ziwoas.example.yml           # Task 14 — checked in, real config is gitignored
├── lib/
│   ├── config_loader.rb             # Task 2 — loads + validates YAML config
│   ├── db.rb                        # Task 3 — Sequel connection + migrations
│   ├── shelly_client.rb             # Task 4 — HTTP client for Shelly RPC API
│   ├── circuit_breaker.rb           # Task 5 — per-plug breaker state machine
│   ├── poller.rb                    # Task 6 — 5s polling loop thread
│   ├── aggregator.rb                # Task 7 + 8 — nightly aggregation + backup
│   ├── savings_calculator.rb        # Task 9 — kWh × €/kWh math
│   └── ziwoas.rb                    # Task 13 — boots all threads + SIGTERM handler
├── app/
│   ├── web.rb                       # Task 10, 11 — Sinatra app + API endpoints
│   └── views/
│       ├── layout.erb               # Task 12 — outer HTML frame
│       └── dashboard.erb            # Task 12 — dashboard page
├── public/
│   ├── htmx.min.js                  # Task 12 — vendored
│   ├── chart.min.js                 # Task 12 — vendored
│   └── app.css                      # Task 12 — hand-written styling
└── test/
    ├── test_helper.rb               # Task 1 — Minitest + WebMock setup
    ├── test_config_loader.rb        # Task 2
    ├── test_db.rb                   # Task 3
    ├── test_shelly_client.rb        # Task 4
    ├── test_circuit_breaker.rb      # Task 5
    ├── test_poller.rb               # Task 6
    ├── test_aggregator.rb           # Task 7, 8
    ├── test_savings_calculator.rb   # Task 9
    └── test_web.rb                  # Task 10, 11
```

**Module naming:** Plain top-level classes (`ConfigLoader`, `ShellyClient`, `CircuitBreaker`, …). The project is a deployable app, not a library; a `Ziwoas::` namespace would add ceremony without value.

---

## Task 1: Project Skeleton, Gemfile, Test Harness

**Files:**
- Create: `Gemfile`, `Rakefile`, `.ruby-version`, `test/test_helper.rb`, `test/test_smoke.rb`

- [ ] **Step 1: Create `.ruby-version`**

```
4.0.2
```

- [ ] **Step 2: Create `Gemfile`**

```ruby
source "https://rubygems.org"

ruby "4.0.2"

gem "sinatra",  "~> 4.1"
gem "sequel",   "~> 5.87"
gem "sqlite3",  "~> 2.3"
gem "puma",     "~> 6.5"
gem "rackup",   "~> 2.2"
gem "logger"                 # stdlib-extracted in Ruby 3.5+
gem "tzinfo",   "~> 2.0"
gem "tzinfo-data"            # safe for containers without system tzdata

group :test do
  gem "minitest",   "~> 5.25"
  gem "rack-test",  "~> 2.2"
  gem "webmock",    "~> 3.25"
end
```

- [ ] **Step 3: Create `Rakefile`**

```ruby
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/test_*.rb"]
  t.warning = false
end

task default: :test
```

- [ ] **Step 4: Create `test/test_helper.rb`**

```ruby
ENV["RACK_ENV"] = "test"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../app", __dir__)

require "minitest/autorun"
require "webmock/minitest"

WebMock.disable_net_connect!(allow_localhost: true)
```

- [ ] **Step 5: Create `test/test_smoke.rb` (proves the harness works)**

```ruby
require "test_helper"

class SmokeTest < Minitest::Test
  def test_the_sky_is_blue
    assert_equal 4, 2 + 2
  end
end
```

- [ ] **Step 6: Install gems and run tests**

Run:
```bash
bundle install
bundle exec rake test
```
Expected: 1 test, 1 assertion, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add .ruby-version Gemfile Gemfile.lock Rakefile test/
git commit -m "Initialize Ruby project skeleton with test harness"
```

---

## Task 2: ConfigLoader

**Files:**
- Create: `lib/config_loader.rb`, `test/test_config_loader.rb`

The loader reads `config/ziwoas.yml` (path overridable), validates strictly, and returns an immutable data object. Invalid config → raises a clear error that the main entrypoint converts to `exit 1`.

- [ ] **Step 1: Write failing tests for ConfigLoader**

`test/test_config_loader.rb`:

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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rake test TEST=test/test_config_loader.rb`
Expected: All tests fail with `NameError: uninitialized constant ConfigLoader` or similar.

- [ ] **Step 3: Implement `lib/config_loader.rb`**

```ruby
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rake test TEST=test/test_config_loader.rb`
Expected: 7 tests, all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/config_loader.rb test/test_config_loader.rb
git commit -m "Add ConfigLoader with strict YAML validation"
```

---

## Task 3: Database Setup + Migrations

**Files:**
- Create: `lib/db.rb`, `test/test_db.rb`

- [ ] **Step 1: Write failing test**

`test/test_db.rb`:

```ruby
require "test_helper"
require "db"

class DbTest < Minitest::Test
  def setup
    @db = DB.connect(":memory:")
    DB.migrate!(@db)
  end

  def test_samples_schema
    @db[:samples].insert(plug_id: "bkw", ts: 1_700_000_000, apower_w: 300.5, aenergy_wh: 12_345.6)
    row = @db[:samples].first
    assert_equal "bkw", row[:plug_id]
    assert_equal 1_700_000_000, row[:ts]
    assert_in_delta 300.5, row[:apower_w]
  end

  def test_samples_composite_primary_key_prevents_duplicates
    @db[:samples].insert(plug_id: "bkw", ts: 100, apower_w: 1, aenergy_wh: 1)
    assert_raises(Sequel::UniqueConstraintViolation) do
      @db[:samples].insert(plug_id: "bkw", ts: 100, apower_w: 2, aenergy_wh: 2)
    end
  end

  def test_samples_5min_schema
    @db[:samples_5min].insert(
      plug_id: "bkw", bucket_ts: 1_700_000_000,
      avg_power_w: 250.0, energy_delta_wh: 20.8, sample_count: 60
    )
    assert_equal 1, @db[:samples_5min].count
  end

  def test_daily_totals_schema
    @db[:daily_totals].insert(plug_id: "bkw", date: "2026-04-13", energy_wh: 1240.5)
    assert_in_delta 1240.5, @db[:daily_totals].first[:energy_wh]
  end

  def test_migrate_is_idempotent
    DB.migrate!(@db)  # second call should not raise
    DB.migrate!(@db)  # third too
    assert true
  end
end
```

- [ ] **Step 2: Run tests — they should fail with `NameError: uninitialized constant DB`**

Run: `bundle exec rake test TEST=test/test_db.rb`

- [ ] **Step 3: Implement `lib/db.rb`**

```ruby
require "sequel"

module DB
  def self.connect(path)
    db = Sequel.sqlite(path)
    db.run "PRAGMA journal_mode = WAL;"         unless path == ":memory:"
    db.run "PRAGMA foreign_keys = ON;"
    db
  end

  def self.migrate!(db)
    unless db.table_exists?(:samples)
      db.create_table(:samples) do
        String  :plug_id,     null: false
        Integer :ts,          null: false
        Float   :apower_w,    null: false
        Float   :aenergy_wh,  null: false
        primary_key [:plug_id, :ts]
      end
      db.add_index :samples, :ts, name: :idx_samples_ts
    end

    unless db.table_exists?(:samples_5min)
      db.create_table(:samples_5min) do
        String  :plug_id,          null: false
        Integer :bucket_ts,        null: false
        Float   :avg_power_w,      null: false
        Float   :energy_delta_wh,  null: false
        Integer :sample_count,     null: false
        primary_key [:plug_id, :bucket_ts]
      end
    end

    unless db.table_exists?(:daily_totals)
      db.create_table(:daily_totals) do
        String  :plug_id,    null: false
        String  :date,       null: false
        Float   :energy_wh,  null: false
        primary_key [:plug_id, :date]
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rake test TEST=test/test_db.rb`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/db.rb test/test_db.rb
git commit -m "Add SQLite schema with idempotent migrations"
```

---

## Task 4: ShellyClient

**Files:**
- Create: `lib/shelly_client.rb`, `test/test_shelly_client.rb`

Talks to `http://<host>/rpc/Switch.GetStatus?id=0` and returns a `Reading` struct. Maps all expected network errors to a single `ShellyClient::Error` subclass so callers have one thing to rescue.

- [ ] **Step 1: Write failing tests**

`test/test_shelly_client.rb`:

```ruby
require "test_helper"
require "shelly_client"
require "json"

class ShellyClientTest < Minitest::Test
  def setup
    @client = ShellyClient.new(timeout: 2)
  end

  def shelly_response
    { "id" => 0, "apower" => 342.5, "aenergy" => { "total" => 12_345.67 } }.to_json
  end

  def test_parses_successful_response
    stub_request(:get, "http://192.168.1.192/rpc/Switch.GetStatus?id=0")
      .to_return(status: 200, body: shelly_response, headers: { "Content-Type" => "application/json" })

    reading = @client.fetch("192.168.1.192")
    assert_in_delta 342.5, reading.apower_w
    assert_in_delta 12_345.67, reading.aenergy_wh
  end

  def test_raises_on_non_200
    stub_request(:get, /.*/).to_return(status: 503, body: "boot")
    assert_raises(ShellyClient::Error) { @client.fetch("192.168.1.192") }
  end

  def test_raises_on_timeout
    stub_request(:get, /.*/).to_timeout
    assert_raises(ShellyClient::Error) { @client.fetch("192.168.1.192") }
  end

  def test_raises_on_connection_refused
    stub_request(:get, /.*/).to_raise(Errno::ECONNREFUSED)
    assert_raises(ShellyClient::Error) { @client.fetch("192.168.1.192") }
  end

  def test_raises_on_malformed_json
    stub_request(:get, /.*/).to_return(status: 200, body: "not json")
    assert_raises(ShellyClient::Error) { @client.fetch("192.168.1.192") }
  end

  def test_raises_on_missing_fields
    stub_request(:get, /.*/).to_return(status: 200, body: "{}")
    assert_raises(ShellyClient::Error) { @client.fetch("192.168.1.192") }
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rake test TEST=test/test_shelly_client.rb`

- [ ] **Step 3: Implement `lib/shelly_client.rb`**

```ruby
require "net/http"
require "json"
require "uri"

class ShellyClient
  class Error < StandardError; end

  Reading = Struct.new(:apower_w, :aenergy_wh, keyword_init: true)

  NETWORK_ERRORS = [
    Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout,
    Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
    Errno::ETIMEDOUT, SocketError, EOFError,
  ].freeze

  def initialize(timeout: 2)
    @timeout = timeout
  end

  def fetch(host)
    uri = URI("http://#{host}/rpc/Switch.GetStatus?id=0")
    response = get(uri)
    raise Error, "HTTP #{response.code} from #{host}" unless response.is_a?(Net::HTTPSuccess)

    parse(response.body, host)
  rescue *NETWORK_ERRORS => e
    raise Error, "#{e.class}: #{e.message}"
  end

  private

  def get(uri)
    Net::HTTP.start(uri.host, uri.port,
                    open_timeout: @timeout, read_timeout: @timeout) do |http|
      http.request(Net::HTTP::Get.new(uri.request_uri))
    end
  end

  def parse(body, host)
    data = JSON.parse(body)
    apower  = data["apower"]
    aenergy = data.dig("aenergy", "total")
    raise Error, "missing apower/aenergy from #{host}" if apower.nil? || aenergy.nil?

    Reading.new(apower_w: apower.to_f, aenergy_wh: aenergy.to_f)
  rescue JSON::ParserError => e
    raise Error, "invalid JSON from #{host}: #{e.message}"
  end
end
```

- [ ] **Step 4: Run tests**

Run: `bundle exec rake test TEST=test/test_shelly_client.rb`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/shelly_client.rb test/test_shelly_client.rb
git commit -m "Add ShellyClient with error normalization"
```

---

## Task 5: CircuitBreaker

**Files:**
- Create: `lib/circuit_breaker.rb`, `test/test_circuit_breaker.rb`

In-memory state machine with an injectable `clock` (a lambda returning the current time) so tests are deterministic.

- [ ] **Step 1: Write failing tests**

`test/test_circuit_breaker.rb`:

```ruby
require "test_helper"
require "circuit_breaker"

class CircuitBreakerTest < Minitest::Test
  def setup
    @now = 1_000.0
    @breaker = CircuitBreaker.new(threshold: 3, probe_seconds: 30, clock: -> { @now })
  end

  def test_initial_state_is_closed
    assert_equal :closed, @breaker.state
    refute @breaker.skip?
  end

  def test_opens_after_threshold_failures
    3.times { @breaker.record_failure }
    assert_equal :open, @breaker.state
    assert @breaker.skip?
  end

  def test_stays_closed_below_threshold
    2.times { @breaker.record_failure }
    assert_equal :closed, @breaker.state
  end

  def test_success_resets_failure_counter
    2.times { @breaker.record_failure }
    @breaker.record_success
    2.times { @breaker.record_failure }
    assert_equal :closed, @breaker.state
  end

  def test_skip_false_once_probe_deadline_reached
    3.times { @breaker.record_failure }
    assert @breaker.skip?
    @now += 29.9
    assert @breaker.skip?
    @now += 0.2
    refute @breaker.skip?
  end

  def test_successful_probe_closes_breaker
    3.times { @breaker.record_failure }
    @now += 31
    @breaker.record_success
    assert_equal :closed, @breaker.state
    refute @breaker.skip?
  end

  def test_failed_probe_keeps_open_and_extends_deadline
    3.times { @breaker.record_failure }
    @now += 31
    refute @breaker.skip?            # allowed to probe now
    @breaker.record_failure          # probe fails
    assert @breaker.skip?            # skipping again
  end

  def test_transitions_yield_state_change
    changes = []
    breaker = CircuitBreaker.new(threshold: 2, probe_seconds: 10, clock: -> { @now }) do |from, to|
      changes << [from, to]
    end
    breaker.record_failure
    breaker.record_failure          # closed → open
    @now += 11
    breaker.record_success          # open → closed
    assert_equal [[:closed, :open], [:open, :closed]], changes
  end
end
```

- [ ] **Step 2: Run tests — they should fail**

Run: `bundle exec rake test TEST=test/test_circuit_breaker.rb`

- [ ] **Step 3: Implement `lib/circuit_breaker.rb`**

```ruby
class CircuitBreaker
  attr_reader :state

  def initialize(threshold:, probe_seconds:, clock: -> { Time.now.to_f }, &on_change)
    @threshold      = threshold
    @probe_seconds  = probe_seconds
    @clock          = clock
    @on_change      = on_change
    @state          = :closed
    @failure_count  = 0
    @open_until     = 0
  end

  # True if the caller should skip the next operation this tick.
  def skip?
    @state == :open && @clock.call < @open_until
  end

  def record_success
    transition(:closed) if @state == :open
    @failure_count = 0
  end

  def record_failure
    @failure_count += 1

    if @state == :open
      @open_until = @clock.call + @probe_seconds
    elsif @failure_count >= @threshold
      transition(:open)
      @open_until = @clock.call + @probe_seconds
    end
  end

  private

  def transition(new_state)
    from = @state
    return if from == new_state
    @state = new_state
    @on_change&.call(from, new_state)
  end
end
```

- [ ] **Step 4: Run tests**

Run: `bundle exec rake test TEST=test/test_circuit_breaker.rb`
Expected: 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/circuit_breaker.rb test/test_circuit_breaker.rb
git commit -m "Add per-plug CircuitBreaker state machine"
```

---

## Task 6: Poller

**Files:**
- Create: `lib/poller.rb`, `test/test_poller.rb`

The Poller owns a set of breakers (one per plug), polls each plug per tick, writes successful samples to the DB, and logs breaker state-changes. It exposes `#tick` (one iteration, used for testing) and `#run` (infinite loop with `sleep`, used in production).

- [ ] **Step 1: Write failing tests**

`test/test_poller.rb`:

```ruby
require "test_helper"
require "poller"
require "db"
require "config_loader"
require "logger"
require "stringio"

class PollerTest < Minitest::Test
  def setup
    @db = DB.connect(":memory:")
    DB.migrate!(@db)

    @log_io = StringIO.new
    @logger = Logger.new(@log_io)

    @now = 1_700_000_000.0
    @plugs = [
      ConfigLoader::PlugCfg.new(id: "bkw",    name: "BKW",    role: :producer, host: "10.0.0.1"),
      ConfigLoader::PlugCfg.new(id: "fridge", name: "Fridge", role: :consumer, host: "10.0.0.2"),
    ]

    @poller = Poller.new(
      plugs:    @plugs,
      db:       @db,
      client:   fake_client,
      logger:   @logger,
      breaker_opts: { threshold: 3, probe_seconds: 30 },
      clock:    -> { @now },
    )
  end

  def fake_client
    client = Object.new
    def client.fetch(host) = ShellyClient::Reading.new(apower_w: 100.0, aenergy_wh: 500.0)
    client
  end

  def failing_client(host_to_fail)
    client = Object.new
    client.define_singleton_method(:fetch) do |host|
      raise ShellyClient::Error, "boom" if host == host_to_fail
      ShellyClient::Reading.new(apower_w: 100.0, aenergy_wh: 500.0)
    end
    client
  end

  def test_successful_tick_inserts_one_row_per_plug
    @poller.tick
    assert_equal 2, @db[:samples].count
    ids = @db[:samples].map(:plug_id).sort
    assert_equal %w[bkw fridge], ids
  end

  def test_failing_plug_does_not_block_others
    @poller = Poller.new(
      plugs:    @plugs,
      db:       @db,
      client:   failing_client("10.0.0.1"),
      logger:   @logger,
      breaker_opts: { threshold: 3, probe_seconds: 30 },
      clock:    -> { @now },
    )
    @poller.tick
    assert_equal 1, @db[:samples].count
    assert_equal "fridge", @db[:samples].first[:plug_id]
  end

  def test_breaker_opens_after_threshold
    @poller = Poller.new(
      plugs:    @plugs,
      db:       @db,
      client:   failing_client("10.0.0.1"),
      logger:   @logger,
      breaker_opts: { threshold: 3, probe_seconds: 30 },
      clock:    -> { @now },
    )
    3.times { @poller.tick }
    assert_match(/opening breaker.*bkw/i, @log_io.string)
  end

  def test_only_logs_state_changes
    failing = failing_client("10.0.0.1")
    @poller = Poller.new(plugs: @plugs, db: @db, client: failing, logger: @logger,
                         breaker_opts: { threshold: 3, probe_seconds: 30 }, clock: -> { @now })
    10.times { @poller.tick }
    opens = @log_io.string.scan(/opening breaker/).length
    assert_equal 1, opens
  end

  def test_timestamp_is_unix_seconds
    @poller.tick
    ts = @db[:samples].first[:ts]
    assert_equal @now.to_i, ts
  end
end
```

- [ ] **Step 2: Run tests — expect failures**

Run: `bundle exec rake test TEST=test/test_poller.rb`

- [ ] **Step 3: Implement `lib/poller.rb`**

```ruby
require "shelly_client"
require "circuit_breaker"

class Poller
  def initialize(plugs:, db:, client:, logger:, breaker_opts:, clock: -> { Time.now.to_f })
    @plugs    = plugs
    @db       = db
    @client   = client
    @logger   = logger
    @clock    = clock
    @breakers = plugs.to_h do |plug|
      [plug.id, build_breaker(plug, breaker_opts)]
    end
    @stopping = false
  end

  def tick
    ts = @clock.call.to_i
    @plugs.each do |plug|
      breaker = @breakers[plug.id]
      next if breaker.skip?

      begin
        reading = @client.fetch(plug.host)
        @db[:samples].insert(
          plug_id:    plug.id,
          ts:         ts,
          apower_w:   reading.apower_w,
          aenergy_wh: reading.aenergy_wh,
        )
        breaker.record_success
      rescue ShellyClient::Error => e
        breaker.record_failure
        @logger.debug("plug #{plug.id} poll failed: #{e.message}")
      rescue Sequel::UniqueConstraintViolation
        # Duplicate ts (can happen on clock skew). Swallow to keep the loop alive.
      end
    end
  end

  def run(interval)
    until @stopping
      start = @clock.call
      tick
      elapsed = @clock.call - start
      sleep_for = interval - elapsed
      sleep(sleep_for) if sleep_for.positive? && !@stopping
    end
  end

  def stop!
    @stopping = true
  end

  private

  def build_breaker(plug, opts)
    logger = @logger
    id     = plug.id
    CircuitBreaker.new(
      threshold:     opts[:threshold],
      probe_seconds: opts[:probe_seconds],
      clock:         @clock,
    ) do |from, to|
      if to == :open
        logger.warn("opening breaker for plug #{id} after consecutive failures")
      elsif to == :closed
        logger.info("plug #{id} recovered, closing breaker")
      end
    end
  end
end
```

- [ ] **Step 4: Run tests**

Run: `bundle exec rake test TEST=test/test_poller.rb`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/poller.rb test/test_poller.rb
git commit -m "Add Poller that writes samples and logs breaker transitions"
```

---

## Task 7: Aggregator (buckets + daily totals + purge)

**Files:**
- Create: `lib/aggregator.rb`, `test/test_aggregator.rb`

Exposes `#aggregate_day(date)` (pure, testable) and `#run_once` (purge + aggregate recent days). Thread lifecycle comes in Task 13.

- [ ] **Step 1: Write failing tests**

`test/test_aggregator.rb`:

```ruby
require "test_helper"
require "aggregator"
require "db"
require "tzinfo"

class AggregatorTest < Minitest::Test
  def setup
    @db = DB.connect(":memory:")
    DB.migrate!(@db)
    @tz = TZInfo::Timezone.get("Europe/Berlin")
    @aggregator = Aggregator.new(db: @db, timezone: @tz, raw_retention_days: 7)
  end

  # Local Europe/Berlin date "2026-04-10" = 2026-04-10 00:00 Berlin = 22:00 UTC previous day
  def berlin_midnight_utc(date_s)
    @tz.local_to_utc(Time.parse("#{date_s} 00:00:00")).to_i
  end

  def seed_day(plug_id:, date:, start_power:, end_power:, start_energy:, end_energy:)
    start_ts = berlin_midnight_utc(date)
    end_ts   = berlin_midnight_utc(date) + 86_400 - 1
    # 24 samples, one per hour
    (0..23).each do |h|
      ratio = h / 23.0
      @db[:samples].insert(
        plug_id: plug_id,
        ts:      start_ts + h * 3600,
        apower_w:   start_power  + (end_power  - start_power)  * ratio,
        aenergy_wh: start_energy + (end_energy - start_energy) * ratio,
      )
    end
  end

  def test_daily_total_is_energy_delta
    seed_day(plug_id: "bkw", date: "2026-04-10",
             start_power: 0, end_power: 0, start_energy: 1000.0, end_energy: 1800.0)
    @aggregator.aggregate_day("2026-04-10")
    row = @db[:daily_totals].first(plug_id: "bkw", date: "2026-04-10")
    assert_in_delta 800.0, row[:energy_wh]
  end

  def test_5min_buckets_are_populated
    seed_day(plug_id: "bkw", date: "2026-04-10",
             start_power: 100, end_power: 100, start_energy: 0, end_energy: 2400)
    @aggregator.aggregate_day("2026-04-10")
    count = @db[:samples_5min].where(plug_id: "bkw").count
    assert_operator count, :>, 20
  end

  def test_aggregate_day_is_idempotent
    seed_day(plug_id: "bkw", date: "2026-04-10",
             start_power: 50, end_power: 50, start_energy: 0, end_energy: 1200)
    @aggregator.aggregate_day("2026-04-10")
    first_count_5min = @db[:samples_5min].count
    first_total      = @db[:daily_totals].first[:energy_wh]
    @aggregator.aggregate_day("2026-04-10")
    assert_equal first_count_5min, @db[:samples_5min].count
    assert_in_delta first_total, @db[:daily_totals].first[:energy_wh]
  end

  def test_purge_deletes_samples_older_than_retention
    old_ts   = Time.now.to_i - 10 * 86_400
    fresh_ts = Time.now.to_i - 1 * 86_400
    @db[:samples].insert(plug_id: "bkw", ts: old_ts,   apower_w: 1, aenergy_wh: 1)
    @db[:samples].insert(plug_id: "bkw", ts: fresh_ts, apower_w: 2, aenergy_wh: 2)
    @aggregator.purge_old_raw!
    remaining_ts = @db[:samples].map(:ts)
    assert_equal [fresh_ts], remaining_ts
  end

  def test_ignores_days_with_no_samples
    @aggregator.aggregate_day("1999-01-01") # must not raise
    assert_equal 0, @db[:daily_totals].count
  end
end
```

- [ ] **Step 2: Run tests — expect failures**

Run: `bundle exec rake test TEST=test/test_aggregator.rb`

- [ ] **Step 3: Implement `lib/aggregator.rb` (backup comes in Task 8)**

```ruby
require "time"

class Aggregator
  def initialize(db:, timezone:, raw_retention_days:)
    @db = db
    @tz = timezone
    @raw_retention_days = raw_retention_days
  end

  def aggregate_day(date_s)
    start_ts = @tz.local_to_utc(Time.parse("#{date_s} 00:00:00")).to_i
    end_ts   = start_ts + 86_400

    @db.transaction do
      @db[:samples_5min]
        .where(bucket_ts: start_ts..(end_ts - 1))
        .delete
      @db[:daily_totals].where(date: date_s).delete

      @db.run(<<~SQL, start_ts, end_ts)
        INSERT INTO samples_5min (plug_id, bucket_ts, avg_power_w, energy_delta_wh, sample_count)
        SELECT plug_id,
               (ts / 300) * 300                       AS bucket_ts,
               AVG(apower_w)                          AS avg_power_w,
               MAX(aenergy_wh) - MIN(aenergy_wh)      AS energy_delta_wh,
               COUNT(*)                               AS sample_count
          FROM samples
         WHERE ts >= ? AND ts < ?
         GROUP BY plug_id, bucket_ts
      SQL

      @db.run(<<~SQL, date_s, start_ts, end_ts)
        INSERT INTO daily_totals (plug_id, date, energy_wh)
        SELECT plug_id, ?,
               MAX(aenergy_wh) - MIN(aenergy_wh) AS energy_wh
          FROM samples
         WHERE ts >= ? AND ts < ?
         GROUP BY plug_id
      SQL
    end
  end

  def purge_old_raw!
    cutoff = Time.now.to_i - @raw_retention_days * 86_400
    @db[:samples].where { ts < cutoff }.delete
  end

  # Aggregate any finished day not yet in daily_totals, then purge.
  def run_once(today: Date.today)
    existing = @db[:daily_totals].select_map(:date).uniq.to_set
    earliest = earliest_sample_date
    return if earliest.nil?

    (earliest..(today - 1)).each do |d|
      date_s = d.to_s
      next if existing.include?(date_s)
      aggregate_day(date_s)
    end

    purge_old_raw!
  end

  private

  def earliest_sample_date
    min_ts = @db[:samples].min(:ts)
    return nil if min_ts.nil?
    Time.at(min_ts).utc.to_date
  end
end
```

Add to the top of the file (since `run_once` uses them):

```ruby
require "date"
require "set"
```

- [ ] **Step 4: Run tests**

Run: `bundle exec rake test TEST=test/test_aggregator.rb`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/aggregator.rb test/test_aggregator.rb
git commit -m "Add Aggregator for 5-min buckets, daily totals, retention purge"
```

---

## Task 8: SQLite Backup Job

**Files:**
- Modify: `lib/aggregator.rb`, `test/test_aggregator.rb`

Add `#backup!(dir)` that writes `ziwoas-YYYY-MM-DD.db` into `dir` and keeps only the 7 most recent snapshots.

- [ ] **Step 1: Extend the test file**

Append to `test/test_aggregator.rb`:

```ruby
  def test_backup_creates_sqlite_file
    Dir.mktmpdir do |tmp|
      # switch DB to a file so .backup has something real
      file_db = File.join(tmp, "live.db")
      db = DB.connect(file_db)
      DB.migrate!(db)
      db[:samples].insert(plug_id: "bkw", ts: 1, apower_w: 0, aenergy_wh: 0)

      agg = Aggregator.new(db: db, timezone: @tz, raw_retention_days: 7)
      backup_dir = File.join(tmp, "backup")
      agg.backup!(backup_dir)

      files = Dir.glob("#{backup_dir}/*.db")
      assert_equal 1, files.length
      assert_match(/ziwoas-\d{4}-\d{2}-\d{2}\.db\z/, files.first)
      assert File.size(files.first) > 0

      # Backup file is itself a valid SQLite DB
      restored = DB.connect(files.first)
      assert_equal 1, restored[:samples].count
    end
  end

  def test_backup_keeps_only_7_most_recent
    Dir.mktmpdir do |tmp|
      file_db = File.join(tmp, "live.db")
      db = DB.connect(file_db)
      DB.migrate!(db)
      backup_dir = File.join(tmp, "backup")
      FileUtils.mkdir_p(backup_dir)

      # Pre-seed 10 fake snapshots with staggered mtimes
      10.times do |i|
        path = File.join(backup_dir, "ziwoas-2026-04-#{format('%02d', i + 1)}.db")
        File.write(path, "fake#{i}")
        File.utime(Time.now - (10 - i) * 86_400, Time.now - (10 - i) * 86_400, path)
      end

      agg = Aggregator.new(db: db, timezone: @tz, raw_retention_days: 7)
      agg.backup!(backup_dir)

      remaining = Dir.glob("#{backup_dir}/*.db").map { |f| File.basename(f) }.sort
      assert_equal 7, remaining.length
      # 6 pre-seeded + 1 fresh snapshot from this run
      assert(remaining.any? { |f| f.include?(Date.today.to_s) })
    end
  end
```

Also add to the top of the file if not already there:

```ruby
require "fileutils"
require "tmpdir"
```

- [ ] **Step 2: Run tests — expect failures**

Run: `bundle exec rake test TEST=test/test_aggregator.rb`

- [ ] **Step 3: Add `#backup!` to `lib/aggregator.rb`**

Also add `require "fileutils"` to the top of the file.

Insert this method into the `Aggregator` class, right after `purge_old_raw!`. We use SQLite's `VACUUM INTO` — single-call, guarantees a consistent snapshot even during writes, requires no `sqlite3-ruby` Backup API specifics. Destination file must not exist (SQLite contract).

```ruby
  def backup!(backup_dir, today: Date.today, keep: 7)
    FileUtils.mkdir_p(backup_dir)
    filename = File.join(backup_dir, "ziwoas-#{today}.db")
    File.delete(filename) if File.exist?(filename)

    @db.run("VACUUM INTO ?", filename)

    prune_old_backups(backup_dir, keep)
  end
```

Move `earliest_sample_date` down and add `prune_old_backups` under the existing `private` marker:

```ruby
  private

  def earliest_sample_date
    min_ts = @db[:samples].min(:ts)
    return nil if min_ts.nil?
    Time.at(min_ts).utc.to_date
  end

  def prune_old_backups(dir, keep)
    files = Dir.glob("#{dir}/ziwoas-*.db").sort_by { |f| File.mtime(f) }
    (files.length - keep).times { File.delete(files.shift) } if files.length > keep
  end
```

- [ ] **Step 4: Run tests**

Run: `bundle exec rake test TEST=test/test_aggregator.rb`
Expected: 7 tests pass total (including the two new ones).

- [ ] **Step 5: Commit**

```bash
git add lib/aggregator.rb test/test_aggregator.rb
git commit -m "Add SQLite online backup with 7-day rotation"
```

---

## Task 9: SavingsCalculator

**Files:**
- Create: `lib/savings_calculator.rb`, `test/test_savings_calculator.rb`

Trivial math class, but having it isolated makes the web layer trivially testable.

- [ ] **Step 1: Write failing tests**

`test/test_savings_calculator.rb`:

```ruby
require "test_helper"
require "savings_calculator"

class SavingsCalculatorTest < Minitest::Test
  def test_savings_is_kwh_times_price
    calc = SavingsCalculator.new(price_eur_per_kwh: 0.32)
    assert_in_delta 0.32, calc.savings_eur(1_000.0)
    assert_in_delta 0.0,  calc.savings_eur(0.0)
    assert_in_delta 0.08, calc.savings_eur(250.0)
  end

  def test_negative_energy_yields_zero_savings
    calc = SavingsCalculator.new(price_eur_per_kwh: 0.32)
    assert_in_delta 0.0, calc.savings_eur(-50.0)
  end
end
```

- [ ] **Step 2: Run tests — expect failure**

Run: `bundle exec rake test TEST=test/test_savings_calculator.rb`

- [ ] **Step 3: Implement `lib/savings_calculator.rb`**

```ruby
class SavingsCalculator
  def initialize(price_eur_per_kwh:)
    @price = price_eur_per_kwh
  end

  def savings_eur(energy_wh)
    return 0.0 if energy_wh.nil? || energy_wh < 0
    (energy_wh / 1000.0) * @price
  end
end
```

- [ ] **Step 4: Run tests**

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/savings_calculator.rb test/test_savings_calculator.rb
git commit -m "Add SavingsCalculator"
```

---

## Task 10: Sinatra Skeleton + `/api/live`

**Files:**
- Create: `app/web.rb`, `config.ru`, `test/test_web.rb`

Sinatra app read from `ENV["CONFIG_PATH"]` and `ENV["DATABASE_PATH"]`. The test harness passes them in via `ENV` before requiring the app, so tests can point at `:memory:` DBs and in-memory configs.

- [ ] **Step 1: Write failing tests**

`test/test_web.rb`:

```ruby
require "test_helper"
require "rack/test"
require "tempfile"
require "json"

class WebTest < Minitest::Test
  include Rack::Test::Methods

  def app
    @app ||= begin
      cfg = Tempfile.new(["cfg", ".yml"])
      cfg.write(<<~YAML); cfg.flush
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
            host: 10.0.0.1
          - id: fridge
            name: Kühlschrank
            role: consumer
            host: 10.0.0.2
      YAML

      ENV["CONFIG_PATH"]   = cfg.path
      ENV["DATABASE_PATH"] = ":memory:"
      require "web"
      Web
    end
  end

  def setup
    # Reset DB each test
    Web.settings.db[:samples].delete
  end

  def test_api_live_returns_offline_when_no_samples
    get "/api/live"
    assert_equal 200, last_response.status
    data = JSON.parse(last_response.body)
    assert_equal 2, data["plugs"].length
    assert data["plugs"].all? { |p| p["online"] == false }
  end

  def test_api_live_returns_current_values_after_sample
    now = Time.now.to_i
    Web.settings.db[:samples].insert(plug_id: "bkw", ts: now - 2, apower_w: 342.5, aenergy_wh: 1000.0)
    get "/api/live"
    bkw = JSON.parse(last_response.body)["plugs"].find { |p| p["id"] == "bkw" }
    assert_equal true, bkw["online"]
    assert_in_delta 342.5, bkw["apower_w"]
  end

  def test_api_live_marks_stale_sample_as_offline
    old = Time.now.to_i - 60
    Web.settings.db[:samples].insert(plug_id: "bkw", ts: old, apower_w: 1.0, aenergy_wh: 1.0)
    get "/api/live"
    bkw = JSON.parse(last_response.body)["plugs"].find { |p| p["id"] == "bkw" }
    assert_equal false, bkw["online"]
  end
end
```

- [ ] **Step 2: Run tests — expect failure (Web not defined)**

Run: `bundle exec rake test TEST=test/test_web.rb`

- [ ] **Step 3: Create `app/web.rb`**

```ruby
require "sinatra/base"
require "json"
require "config_loader"
require "db"

class Web < Sinatra::Base
  configure do
    config_path   = ENV.fetch("CONFIG_PATH")
    database_path = ENV.fetch("DATABASE_PATH")

    config = ConfigLoader.load(config_path)
    db     = DB.connect(database_path)
    DB.migrate!(db)

    set :config, config
    set :db, db
    set :stale_threshold_seconds, config.poll.interval_seconds * 2
  end

  helpers do
    def json_response(data)
      content_type :json
      data.to_json
    end
  end

  get "/api/live" do
    threshold = settings.stale_threshold_seconds
    now       = Time.now.to_i

    plugs = settings.config.plugs.map do |plug|
      latest = settings.db[:samples].where(plug_id: plug.id).order(Sequel.desc(:ts)).first
      online = !latest.nil? && (now - latest[:ts]) <= threshold
      {
        id:             plug.id,
        name:           plug.name,
        role:           plug.role,
        online:         online,
        apower_w:       online ? latest[:apower_w] : nil,
        last_seen_ts:   latest&.dig(:ts),
      }
    end

    json_response(plugs: plugs, now_ts: now)
  end
end
```

- [ ] **Step 4: Create `config.ru` (for Puma)**

```ruby
$LOAD_PATH.unshift File.expand_path("lib", __dir__)
$LOAD_PATH.unshift File.expand_path("app", __dir__)

require "web"
run Web
```

- [ ] **Step 5: Run tests**

Run: `bundle exec rake test TEST=test/test_web.rb`
Expected: 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add app/web.rb config.ru test/test_web.rb
git commit -m "Add Sinatra app skeleton with /api/live endpoint"
```

---

## Task 11: `/api/today`, `/api/today/summary`, `/api/history`

**Files:**
- Modify: `app/web.rb`, `test/test_web.rb`

- [ ] **Step 1: Add failing tests**

Append to `test/test_web.rb`:

```ruby
  def test_api_today_returns_per_minute_series_per_plug
    tz        = TZInfo::Timezone.get("Europe/Berlin")
    today_utc = tz.local_to_utc(Time.now).to_date  # crude but fine for the test
    midnight  = tz.local_to_utc(Time.parse("#{Date.today} 00:00:00")).to_i
    Web.settings.db[:samples].insert(plug_id: "bkw", ts: midnight + 120,
                                     apower_w: 200.0, aenergy_wh: 100.0)
    Web.settings.db[:samples].insert(plug_id: "bkw", ts: midnight + 180,
                                     apower_w: 300.0, aenergy_wh: 110.0)

    get "/api/today"
    assert_equal 200, last_response.status
    data = JSON.parse(last_response.body)
    bkw  = data["series"].find { |s| s["plug_id"] == "bkw" }
    refute_nil bkw
    assert bkw["points"].length >= 1
    point = bkw["points"].first
    assert point.key?("ts")
    assert point.key?("avg_power_w")
  end

  def test_api_today_summary_calculates_savings
    tz       = TZInfo::Timezone.get("Europe/Berlin")
    midnight = tz.local_to_utc(Time.parse("#{Date.today} 00:00:00")).to_i
    Web.settings.db[:samples].insert(plug_id: "bkw",    ts: midnight + 60,
                                     apower_w: 0, aenergy_wh: 0)
    Web.settings.db[:samples].insert(plug_id: "bkw",    ts: midnight + 3600,
                                     apower_w: 0, aenergy_wh: 1000.0)  # 1 kWh today
    Web.settings.db[:samples].insert(plug_id: "fridge", ts: midnight + 60,
                                     apower_w: 0, aenergy_wh: 500.0)
    Web.settings.db[:samples].insert(plug_id: "fridge", ts: midnight + 3600,
                                     apower_w: 0, aenergy_wh: 600.0)   # 0.1 kWh today

    get "/api/today/summary"
    data = JSON.parse(last_response.body)
    assert_in_delta 1000.0, data["produced_wh_today"]
    assert_in_delta 100.0,  data["consumed_wh_today"]
    assert_in_delta 0.32,   data["savings_eur_today"]
  end

  def test_api_history_returns_n_days
    tz     = TZInfo::Timezone.get("Europe/Berlin")
    today  = Date.today
    7.times do |i|
      d = today - (i + 1)
      Web.settings.db[:daily_totals].insert(plug_id: "bkw", date: d.to_s, energy_wh: 1000 + i * 100)
    end
    get "/api/history?days=5"
    data = JSON.parse(last_response.body)
    bkw  = data["series"].find { |s| s["plug_id"] == "bkw" }
    assert_equal 5, bkw["points"].length
    assert bkw["points"].first["date"] < bkw["points"].last["date"]  # sorted ascending
  end
```

- [ ] **Step 2: Run tests — expect 3 failures (404s or missing keys)**

Run: `bundle exec rake test TEST=test/test_web.rb`

- [ ] **Step 3: Add endpoints to `app/web.rb`**

Add these `require`s at the top:

```ruby
require "tzinfo"
require "savings_calculator"
require "date"
require "time"
```

Add inside the `Web < Sinatra::Base` block, after the existing `configure`:

```ruby
  helpers do
    def local_tz
      @local_tz ||= TZInfo::Timezone.get(settings.config.timezone)
    end

    def today_bounds_utc
      now_utc     = Time.now.utc
      local_today = local_tz.utc_to_local(now_utc).to_date
      midnight    = Time.new(local_today.year, local_today.month, local_today.day, 0, 0, 0)
      start_utc   = local_tz.local_to_utc(midnight).to_i
      [start_utc, start_utc + 86_400, local_today]
    end

    def producer_ids
      settings.config.plugs.select { |p| p.role == :producer }.map(&:id)
    end

    def consumer_ids
      settings.config.plugs.select { |p| p.role == :consumer }.map(&:id)
    end
  end
```

Then add the three routes:

```ruby
  get "/api/today" do
    start_ts, end_ts, _today = today_bounds_utc

    grouped = settings.db[:samples]
      .where(ts: start_ts..(end_ts - 1))
      .select_group(:plug_id, Sequel.lit("(ts / 60) * 60").as(:minute_ts))
      .select_append(Sequel.function(:avg, :apower_w).as(:avg_power_w))
      .all

    series = settings.config.plugs.map do |plug|
      points = grouped
        .select { |r| r[:plug_id] == plug.id }
        .map { |r| { ts: r[:minute_ts], avg_power_w: r[:avg_power_w].to_f } }
        .sort_by { |p| p[:ts] }
      { plug_id: plug.id, name: plug.name, role: plug.role, points: points }
    end

    json_response(series: series)
  end

  get "/api/today/summary" do
    start_ts, end_ts, today = today_bounds_utc
    calc = SavingsCalculator.new(price_eur_per_kwh: settings.config.electricity_price_eur_per_kwh)

    produced = energy_delta_wh(producer_ids, start_ts, end_ts)
    consumed = energy_delta_wh(consumer_ids, start_ts, end_ts)
    savings  = calc.savings_eur(produced)

    json_response(
      date:                today.to_s,
      produced_wh_today:   produced,
      consumed_wh_today:   consumed,
      savings_eur_today:   savings,
    )
  end

  get "/api/history" do
    days = (params["days"] || "14").to_i.clamp(1, 365)
    cutoff = (Date.today - days).to_s

    rows = settings.db[:daily_totals]
      .where { date > cutoff }
      .order(:date)
      .all

    series = settings.config.plugs.map do |plug|
      points = rows.select { |r| r[:plug_id] == plug.id }
                   .map { |r| { date: r[:date], energy_wh: r[:energy_wh] } }
      { plug_id: plug.id, name: plug.name, role: plug.role, points: points }
    end

    json_response(days: days, series: series)
  end
```

Add the helper method inside the existing `helpers do` block (or create a second one — Sinatra merges them):

```ruby
    def energy_delta_wh(plug_ids, start_ts, end_ts)
      return 0.0 if plug_ids.empty?
      rows = settings.db[:samples]
        .where(plug_id: plug_ids, ts: start_ts..(end_ts - 1))
        .select_group(:plug_id)
        .select_append(
          (Sequel.function(:max, :aenergy_wh) - Sequel.function(:min, :aenergy_wh)).as(:delta)
        )
        .all
      rows.sum { |r| r[:delta] || 0 }.to_f
    end
```

- [ ] **Step 4: Run tests**

Run: `bundle exec rake test TEST=test/test_web.rb`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/web.rb test/test_web.rb
git commit -m "Add /api/today, /api/today/summary, /api/history endpoints"
```

---

## Task 12: Dashboard view (ERB + HTMX + Chart.js + static assets)

**Files:**
- Create: `app/views/layout.erb`, `app/views/dashboard.erb`, `public/app.css`, `public/htmx.min.js`, `public/chart.min.js`
- Modify: `app/web.rb` (add `GET /` and view path)

- [ ] **Step 1: Vendor HTMX and Chart.js**

Run:
```bash
mkdir -p public
curl -sSL -o public/htmx.min.js  https://unpkg.com/htmx.org@2.0.4/dist/htmx.min.js
curl -sSL -o public/chart.min.js https://cdn.jsdelivr.net/npm/chart.js@4.4.6/dist/chart.umd.js
wc -c public/htmx.min.js public/chart.min.js
```

Expected: both files non-empty (htmx ~50 KB, chart ~200 KB).

- [ ] **Step 2: Create `public/app.css`**

```css
:root {
  --bg: #f8f9fa;
  --card: #ffffff;
  --border: #dee2e6;
  --text: #212529;
  --muted: #6c757d;
  --accent: #f59f00;
  --accent-bg: linear-gradient(135deg, #fff3bf 0%, #ffe066 100%);
  --online: #40c057;
  --offline: #adb5bd;
}

* { box-sizing: border-box; }

body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
  margin: 0; padding: 16px;
  background: var(--bg); color: var(--text);
  max-width: 720px; margin-left: auto; margin-right: auto;
}

h1 { font-size: 18px; margin: 0 0 16px; color: var(--muted); font-weight: 500; }
.section-label { font-size: 11px; color: var(--muted); text-transform: uppercase;
                 letter-spacing: 0.6px; margin: 20px 0 8px; }

.hero {
  background: var(--accent-bg);
  border: 1px solid var(--accent);
  border-radius: 12px;
  padding: 28px 20px;
  text-align: center;
  margin-bottom: 12px;
}
.hero-label { font-size: 12px; color: #7c5e00; text-transform: uppercase; letter-spacing: 0.6px; }
.hero-value { font-size: 56px; font-weight: 700; line-height: 1.1; margin-top: 4px; }
.hero-unit  { font-size: 24px; font-weight: 500; color: #7c5e00; }

.tiles { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; margin-bottom: 16px; }
.tile {
  background: var(--card);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 14px;
}
.tile-label { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.5px; }
.tile-value { font-size: 22px; font-weight: 600; margin-top: 4px; }

.chart-card {
  background: var(--card);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 12px;
  margin-bottom: 12px;
}
.chart-card canvas { width: 100% !important; height: 220px !important; }

.plugs { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 16px; }
.plug-chip {
  background: var(--card);
  border: 1px solid var(--border);
  border-radius: 20px;
  padding: 6px 12px;
  font-size: 13px;
  display: inline-flex;
  align-items: center;
  gap: 8px;
}
.plug-chip.offline { opacity: 0.55; }
.dot { width: 8px; height: 8px; border-radius: 50%; background: var(--online); }
.dot.offline { background: var(--offline); }

@media (max-width: 480px) {
  .tiles { grid-template-columns: 1fr; }
  .hero-value { font-size: 44px; }
}
```

- [ ] **Step 3: Create `app/views/layout.erb`**

```erb
<!DOCTYPE html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ZiWoAS — Stromübersicht</title>
  <link rel="stylesheet" href="/app.css">
  <script src="/htmx.min.js" defer></script>
  <script src="/chart.min.js" defer></script>
</head>
<body>
  <%= yield %>
</body>
</html>
```

- [ ] **Step 4: Create `app/views/dashboard.erb`**

```erb
<h1>Zipfelmaus — Stromübersicht</h1>

<!-- Hero: BKW live -->
<div class="hero"
     hx-get="/api/live"
     hx-trigger="load, every 5s"
     hx-swap="none"
     hx-on::after-request="updateHero(event)">
  <div class="hero-label">Balkonkraftwerk gerade</div>
  <div class="hero-value" id="hero-value">— <span class="hero-unit">W</span></div>
</div>

<!-- Tiles: today's numbers -->
<div class="tiles"
     hx-get="/api/today/summary"
     hx-trigger="load, every 10s"
     hx-swap="none"
     hx-on::after-request="updateSummary(event)">
  <div class="tile">
    <div class="tile-label">Heute erzeugt</div>
    <div class="tile-value" id="tile-produced">—</div>
  </div>
  <div class="tile">
    <div class="tile-label">Heute gespart</div>
    <div class="tile-value" id="tile-savings">—</div>
  </div>
  <div class="tile">
    <div class="tile-label">Verbrauch jetzt</div>
    <div class="tile-value" id="tile-consumption">—</div>
  </div>
</div>

<!-- Today chart -->
<div class="section-label">Heute — Leistung über Zeit</div>
<div class="chart-card">
  <canvas id="today-chart"></canvas>
</div>

<!-- Plug chips -->
<div class="section-label">Steckdosen</div>
<div id="plug-list" class="plugs">—</div>

<!-- History chart -->
<div class="section-label">Letzte 14 Tage — Tages-Ertrag</div>
<div class="chart-card">
  <canvas id="history-chart"></canvas>
</div>

<script>
  // Keep latest /api/live response cached so updateHero and the plug list share data
  let lastLive = null;

  function updateHero(evt) {
    try {
      const data = JSON.parse(evt.detail.xhr.responseText);
      lastLive = data;
      const producer = data.plugs.find(p => p.role === "producer");
      document.getElementById("hero-value").innerHTML =
        (producer && producer.online ? producer.apower_w.toFixed(0) : "—") +
        ' <span class="hero-unit">W</span>';

      const consumers = data.plugs.filter(p => p.role === "consumer");
      const sum = consumers.reduce((s, p) => s + (p.online ? p.apower_w : 0), 0);
      document.getElementById("tile-consumption").textContent = sum.toFixed(0) + " W";

      renderPlugChips(data.plugs, data.now_ts);
    } catch (e) { console.error(e); }
  }

  function updateSummary(evt) {
    try {
      const data = JSON.parse(evt.detail.xhr.responseText);
      document.getElementById("tile-produced").textContent =
        (data.produced_wh_today / 1000).toFixed(2) + " kWh";
      document.getElementById("tile-savings").textContent =
        data.savings_eur_today.toFixed(2).replace(".", ",") + " €";
    } catch (e) { console.error(e); }
  }

  function renderPlugChips(plugs, nowTs) {
    const el = document.getElementById("plug-list");
    el.innerHTML = "";
    for (const p of plugs) {
      const chip = document.createElement("span");
      chip.className = "plug-chip" + (p.online ? "" : " offline");
      const dot = document.createElement("span");
      dot.className = "dot" + (p.online ? "" : " offline");
      chip.appendChild(dot);
      const label = p.online
        ? `${p.name} · ${p.apower_w.toFixed(0)} W`
        : `${p.name} · offline`;
      chip.appendChild(document.createTextNode(label));
      el.appendChild(chip);
    }
  }

  let todayChart, historyChart;

  function loadTodayChart() {
    fetch("/api/today").then(r => r.json()).then(data => {
      const datasets = data.series.map(s => ({
        label: s.name,
        data: s.points.map(pt => ({ x: pt.ts * 1000, y: pt.avg_power_w })),
        tension: 0.2,
        borderColor: s.role === "producer" ? "#f59f00" : "#228be6",
        backgroundColor: s.role === "producer" ? "rgba(245,159,0,0.12)" : "rgba(34,139,230,0.08)",
        fill: s.role === "producer",
      }));
      if (todayChart) todayChart.destroy();
      todayChart = new Chart(document.getElementById("today-chart"), {
        type: "line",
        data: { datasets },
        options: {
          scales: {
            x: { type: "time", time: { unit: "hour" } },
            y: { beginAtZero: true, title: { display: true, text: "Watt" } },
          },
          plugins: { legend: { position: "bottom" } },
          animation: false,
        },
      });
    });
  }

  function loadHistoryChart() {
    fetch("/api/history?days=14").then(r => r.json()).then(data => {
      const producer = data.series.find(s => s.role === "producer");
      if (!producer) return;
      const labels = producer.points.map(p => p.date);
      const values = producer.points.map(p => p.energy_wh / 1000);
      if (historyChart) historyChart.destroy();
      historyChart = new Chart(document.getElementById("history-chart"), {
        type: "bar",
        data: {
          labels,
          datasets: [{ label: "kWh/Tag", data: values, backgroundColor: "#f59f00" }],
        },
        options: {
          scales: { y: { beginAtZero: true, title: { display: true, text: "kWh" } } },
          plugins: { legend: { display: false } },
          animation: false,
        },
      });
    });
  }

  document.addEventListener("DOMContentLoaded", () => {
    loadTodayChart();
    loadHistoryChart();
    setInterval(loadTodayChart, 60_000);
    setInterval(loadHistoryChart, 3_600_000);
  });
</script>
```

- [ ] **Step 5: Note on Chart.js time-axis adapter**

Chart.js time axes require an adapter. We used `type: "time"` with `x: { type: "time", time: { unit: "hour" } }`. Rather than adding another JS dependency, replace the `x` axis with `type: "linear"` and render ticks manually. Update `app/views/dashboard.erb` inside `loadTodayChart`:

```javascript
        scales: {
          x: {
            type: "linear",
            title: { display: true, text: "Uhrzeit" },
            ticks: {
              callback: (v) => {
                const d = new Date(v);
                return d.getHours().toString().padStart(2,"0") + ":" +
                       d.getMinutes().toString().padStart(2,"0");
              },
              stepSize: 3_600_000,
              maxTicksLimit: 9,
            },
          },
          y: { beginAtZero: true, title: { display: true, text: "Watt" } },
        },
```

This keeps us to one vendored JS file.

- [ ] **Step 6: Wire the dashboard into Sinatra**

Modify `app/web.rb`:

Add at the top of the `configure` block:

```ruby
    set :views,  File.expand_path("views", __dir__)
    set :public_folder, File.expand_path("../public", __dir__)
```

Add a root route:

```ruby
  get "/" do
    erb :dashboard
  end
```

- [ ] **Step 7: Append a smoke test to `test/test_web.rb`**

```ruby
  def test_root_serves_dashboard_html
    get "/"
    assert_equal 200, last_response.status
    assert_match(/Zipfelmaus/, last_response.body)
    assert_match(/id="today-chart"/, last_response.body)
  end
```

- [ ] **Step 8: Run tests**

Run: `bundle exec rake test`
Expected: all passing.

- [ ] **Step 9: Manual smoke check**

Run:
```bash
cp config/ziwoas.example.yml config/ziwoas.yml 2>/dev/null || true
# If example doesn't exist yet, create a minimal one pointing at a fake host
cat > config/ziwoas.yml <<'YAML'
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
YAML

mkdir -p data
CONFIG_PATH=config/ziwoas.yml DATABASE_PATH=data/ziwoas.db \
  bundle exec puma -p 4567 config.ru
```

Open `http://localhost:4567` — expect the dashboard frame to render (numbers will be `—` until the real poller writes samples, which is Task 13).

- [ ] **Step 10: Commit**

```bash
git add public/ app/views/ app/web.rb test/test_web.rb
git commit -m "Add dashboard view with HTMX polling and Chart.js graphs"
```

---

## Task 13: Main Entrypoint + Thread Supervision + SIGTERM

**Files:**
- Create: `lib/ziwoas.rb`
- Modify: `config.ru`, `app/web.rb`

The `Ziwoas` module bootstraps the full app: loads config, opens DB, migrates, starts poller and aggregator threads, and registers a SIGTERM handler. In web-serving mode it exposes the Sinatra app.

- [ ] **Step 1: Create `lib/ziwoas.rb`**

```ruby
require "logger"
require "tzinfo"
require "config_loader"
require "db"
require "shelly_client"
require "poller"
require "aggregator"

module Ziwoas
  class App
    attr_reader :config, :db, :logger, :poller, :aggregator

    def self.boot(config_path: ENV.fetch("CONFIG_PATH"),
                  database_path: ENV.fetch("DATABASE_PATH"))
      new(config_path, database_path).tap(&:start_threads!)
    end

    def initialize(config_path, database_path)
      @logger = Logger.new($stdout)
      @logger.level = Logger::INFO
      @config = ConfigLoader.load(config_path)
      @db     = DB.connect(database_path)
      DB.migrate!(@db)
    end

    def start_threads!
      tz = TZInfo::Timezone.get(@config.timezone)
      @poller = Poller.new(
        plugs:        @config.plugs,
        db:           @db,
        client:       ShellyClient.new(timeout: @config.poll.timeout_seconds),
        logger:       @logger,
        breaker_opts: {
          threshold:     @config.poll.circuit_breaker_threshold,
          probe_seconds: @config.poll.circuit_breaker_probe_seconds,
        },
      )
      @aggregator = Aggregator.new(
        db: @db,
        timezone: tz,
        raw_retention_days: @config.aggregator.raw_retention_days,
      )

      @poller_thread    = spawn_thread("poller")     { @poller.run(@config.poll.interval_seconds) }
      @aggregator_thread = spawn_thread("aggregator") { aggregator_loop(tz) }
      install_signal_traps!
    end

    def stop!
      @logger.info("ziwoas: shutting down")
      @poller&.stop!
      @stopping = true
      [@poller_thread, @aggregator_thread].each { |t| t&.join(3) }
    end

    private

    def spawn_thread(name)
      Thread.new do
        Thread.current.name = name
        Thread.current.abort_on_exception = false
        Thread.current.report_on_exception = true
        begin
          yield
        rescue => e
          @logger.error("thread #{name} crashed: #{e.class}: #{e.message}")
          @logger.error(e.backtrace.first(10).join("\n"))
          Process.kill("TERM", Process.pid)
        end
      end
    end

    def aggregator_loop(tz)
      until @stopping
        sleep_until_run_at(tz, @config.aggregator.run_at)
        break if @stopping
        @logger.info("aggregator: starting nightly run")
        @aggregator.run_once
        @aggregator.backup!(File.join(File.dirname(ENV.fetch("DATABASE_PATH")), "backup"))
        @logger.info("aggregator: done")
      end
    end

    def sleep_until_run_at(tz, run_at)
      hour, minute = run_at.split(":").map(&:to_i)
      now_utc      = Time.now.utc
      local_now    = tz.utc_to_local(now_utc)
      target_local = Time.new(local_now.year, local_now.month, local_now.day, hour, minute, 0)
      target_utc   = tz.local_to_utc(target_local)
      target_utc  += 86_400 if target_utc <= now_utc
      sleep_for    = target_utc - now_utc

      # Sleep in short bursts so SIGTERM is responsive.
      while sleep_for > 0 && !@stopping
        chunk = [sleep_for, 5].min
        sleep(chunk)
        sleep_for -= chunk
      end
    end

    def install_signal_traps!
      %w[INT TERM].each do |sig|
        Signal.trap(sig) { stop! }
      end
    end
  end
end
```

- [ ] **Step 2: Modify `config.ru` to boot the full app**

```ruby
$LOAD_PATH.unshift File.expand_path("lib", __dir__)
$LOAD_PATH.unshift File.expand_path("app", __dir__)

require "ziwoas"
require "web"

$ZIWOAS_APP = Ziwoas::App.boot

at_exit { $ZIWOAS_APP.stop! rescue nil }

run Web
```

- [ ] **Step 3: Ensure web tests still pass**

The tests set `ENV["CONFIG_PATH"]` and `ENV["DATABASE_PATH"]` before requiring `web`. They do NOT load `config.ru`, so `Ziwoas::App` is not booted during tests — no threads start, no conflict.

Run: `bundle exec rake test`
Expected: all passing.

- [ ] **Step 4: Manual smoke check with real threads**

```bash
CONFIG_PATH=config/ziwoas.yml DATABASE_PATH=data/ziwoas.db \
  bundle exec puma -p 4567 config.ru
```

In another terminal:
```bash
sqlite3 data/ziwoas.db "SELECT COUNT(*) FROM samples;"
# after a few seconds, should be > 0 (if plug host is reachable)
# or 0 with warning logs (if plug host is unreachable) — both are valid states
```

Check that `Ctrl-C` terminates cleanly within ~5 seconds.

- [ ] **Step 5: Commit**

```bash
git add lib/ziwoas.rb config.ru
git commit -m "Wire poller and aggregator threads with SIGTERM handling"
```

---

## Task 14: Dockerfile, docker-compose.yml, Example Config, README

**Files:**
- Create: `Dockerfile`, `docker-compose.yml`, `config/ziwoas.example.yml`, `README.md`
- Modify: `.gitignore` (add `/config/ziwoas.yml`)

- [ ] **Step 1: Create `Dockerfile`**

```dockerfile
FROM ruby:4.0-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      libsqlite3-dev \
      tzdata \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config set --local deployment 'true' \
 && bundle config set --local without 'test' \
 && bundle install --jobs 4

COPY . .

VOLUME ["/data"]
ENV DATABASE_PATH=/data/ziwoas.db \
    CONFIG_PATH=/app/config/ziwoas.yml \
    TZ=Europe/Berlin \
    RACK_ENV=production

EXPOSE 4567

CMD ["bundle", "exec", "puma", "-p", "4567", "-e", "production", "config.ru"]
```

- [ ] **Step 2: Create `docker-compose.yml`**

```yaml
services:
  ziwoas:
    build: .
    image: ziwoas:latest
    container_name: ziwoas
    restart: unless-stopped
    ports:
      - "4567:4567"
    environment:
      TZ: Europe/Berlin
    volumes:
      - ./data:/data
      - ./config/ziwoas.yml:/app/config/ziwoas.yml:ro
```

- [ ] **Step 3: Create `config/ziwoas.example.yml`**

```yaml
# Copy to config/ziwoas.yml and edit to your setup.
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

  # - id: kuehlschrank
  #   name: Kühlschrank
  #   role: consumer
  #   host: 192.168.1.201
```

- [ ] **Step 4: Update `.gitignore`**

Append:

```
/config/ziwoas.yml
```

- [ ] **Step 5: Create `README.md`**

```markdown
# ZiWoAS — Zipfelmaus-Wohnungs-Automatisierungs-system

Heimautomation fürs Mini-Rack. Erstes Feature: Shelly-Monitoring fürs Balkonkraftwerk und Grundverbraucher.

## Quickstart

```bash
cp config/ziwoas.example.yml config/ziwoas.yml
$EDITOR config/ziwoas.yml
mkdir -p data
docker compose up -d
```

Dashboard: <http://localhost:4567>

## Anforderungen

- Shellys mit Gen2+-API (`/rpc/Switch.GetStatus?id=0`) im selben Netz erreichbar
- Docker + docker-compose

## Backup

Die Anwendung erzeugt nachts um 03:30 einen konsistenten SQLite-Snapshot unter `./data/backup/ziwoas-YYYY-MM-DD.db` und hält die letzten 7 Stück. Das `./data`-Verzeichnis kann per restic/rsync offsite gesichert werden.

## Tests

```bash
bundle install
bundle exec rake test
```

## Spec & Plan

- Design: `docs/superpowers/specs/2026-04-13-shelly-monitoring-design.md`
- Plan:   `docs/superpowers/plans/2026-04-13-shelly-monitoring.md`
```

- [ ] **Step 6: Build and smoke-test the Docker image**

```bash
docker compose build
mkdir -p data
# Make sure config/ziwoas.yml exists and points at a reachable Shelly (or a stub IP for smoke-only)
docker compose up -d
sleep 10
docker compose logs --tail=30
curl -sf http://localhost:4567/api/live | head -c 200
docker compose down
```

Expected: container boots, `/api/live` returns JSON (even with offline plugs), `docker compose down` terminates cleanly.

- [ ] **Step 7: Commit**

```bash
git add Dockerfile docker-compose.yml config/ziwoas.example.yml README.md .gitignore
git commit -m "Add Dockerfile, compose config, example config, README"
```

---

## Done criteria

- [ ] `bundle exec rake test` — all tests pass
- [ ] `docker compose up -d` works with a real config
- [ ] Dashboard at `http://localhost:4567` renders with live values from at least one reachable Shelly
- [ ] Killing the container cleanly (`docker compose down`) terminates within ~5s
- [ ] One plug unplugged from power → dashboard shows it as `offline` within ~10s, other plugs still update
- [ ] After 1 day of runtime, `sqlite3 data/ziwoas.db "SELECT COUNT(*) FROM samples;"` shows the expected volume (~100k rows for 6 plugs)
- [ ] Nightly aggregator run populates `samples_5min` and `daily_totals`, and creates `data/backup/ziwoas-YYYY-MM-DD.db`

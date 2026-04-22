# FritzDectClient Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add FRITZ!DECT plug support by implementing `FritzDectClient` and wiring it into the existing polling infrastructure alongside `ShellyClient`.

**Architecture:** `ShellyClient#fetch` is updated from `fetch(host)` to `fetch(plug)` so all clients share a uniform interface. The `Poller` is updated to hold a `plug_id → client` hash and dispatches `@clients[plug.id].fetch(plug)` per tick. `FritzDectClient` authenticates lazily via Fritz!Box MD5 challenge-response and caches the session ID, re-authenticating transparently on HTTP 403.

**Tech Stack:** Ruby stdlib only (`net/http`, `digest`, `rexml/document`, `uri`). Tests use Minitest + WebMock (already in Gemfile). No new gems required.

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `lib/shelly_client.rb` | Modify | `fetch(host)` → `fetch(plug)` |
| `lib/fritz_dect_client.rb` | Create | Fritz!Box Home Automation API client |
| `lib/config_loader.rb` | Modify | Add `driver:`, `ain:` to `PlugCfg`; add `FritzBoxCfg`; add `fritz_box:` section |
| `lib/poller.rb` | Modify | `client:` → `clients:` hash; rescue both error types |
| `lib/ziwoas.rb` | Modify | Build clients hash; pass to Poller |
| `config/ziwoas.example.yml` | Modify | Add `fritz_box:` block + fritz_dect plug example |
| `test/test_shelly_client.rb` | Modify | Pass plug struct instead of bare host string |
| `test/test_fritz_dect_client.rb` | Create | Full coverage mirroring test_shelly_client.rb |
| `test/test_config_loader.rb` | Modify | Tests for driver/ain/fritz_box validation |
| `test/test_poller.rb` | Modify | Update for `clients:` hash and `fetch(plug)` |

---

## Task 1: Update ShellyClient to accept a plug

**Files:**
- Modify: `lib/shelly_client.rb`
- Modify: `test/test_shelly_client.rb`

- [ ] **Step 1: Update the test to use a plug struct**

Replace the entire `test/test_shelly_client.rb`:

```ruby
require "test_helper"
require "shelly_client"
require "config_loader"
require "json"

class ShellyClientTest < Minitest::Test
  def setup
    @client = ShellyClient.new(timeout: 2)
    @plug   = ConfigLoader::PlugCfg.new(id: "bkw", name: "BKW", role: :producer,
                                         driver: :shelly, host: "192.168.1.192")
  end

  def shelly_response
    { "id" => 0, "apower" => 342.5, "aenergy" => { "total" => 12_345.67 } }.to_json
  end

  def test_parses_successful_response
    stub_request(:get, "http://192.168.1.192/rpc/Switch.GetStatus?id=0")
      .to_return(status: 200, body: shelly_response, headers: { "Content-Type" => "application/json" })

    reading = @client.fetch(@plug)
    assert_in_delta 342.5, reading.apower_w
    assert_in_delta 12_345.67, reading.aenergy_wh
  end

  def test_raises_on_non_200
    stub_request(:get, /.*/).to_return(status: 503, body: "boot")
    assert_raises(ShellyClient::Error) { @client.fetch(@plug) }
  end

  def test_raises_on_timeout
    stub_request(:get, /.*/).to_timeout
    assert_raises(ShellyClient::Error) { @client.fetch(@plug) }
  end

  def test_raises_on_connection_refused
    stub_request(:get, /.*/).to_raise(Errno::ECONNREFUSED)
    assert_raises(ShellyClient::Error) { @client.fetch(@plug) }
  end

  def test_raises_on_malformed_json
    stub_request(:get, /.*/).to_return(status: 200, body: "not json")
    assert_raises(ShellyClient::Error) { @client.fetch(@plug) }
  end

  def test_raises_on_missing_fields
    stub_request(:get, /.*/).to_return(status: 200, body: "{}")
    assert_raises(ShellyClient::Error) { @client.fetch(@plug) }
  end
end
```

- [ ] **Step 2: Run the test — expect failures**

```bash
bundle exec ruby -Itest -Ilib test/test_shelly_client.rb
```

Expected: `ArgumentError` or `NoMethodError` because `fetch` still takes a string, not a plug.

- [ ] **Step 3: Update ShellyClient#fetch**

In `lib/shelly_client.rb`, change the `fetch` method (lines 20–28):

```ruby
def fetch(plug)
  host = plug.host
  uri = URI("http://#{host}/rpc/Switch.GetStatus?id=0")
  response = get(uri)
  raise Error, "HTTP #{response.code} from #{host}" unless response.is_a?(Net::HTTPSuccess)

  parse(response.body, host)
rescue *NETWORK_ERRORS => e
  raise Error, "#{e.class}: #{e.message}"
end
```

- [ ] **Step 4: Run tests — expect all green**

```bash
bundle exec ruby -Itest -Ilib test/test_shelly_client.rb
```

Expected: 6 tests, 0 failures.

- [ ] **Step 5: Run full suite — no regressions**

```bash
bundle exec rake test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/shelly_client.rb test/test_shelly_client.rb
git commit -m "refactor: ShellyClient#fetch accepts plug instead of bare host string"
```

---

## Task 2: Extend ConfigLoader with driver, ain, and fritz_box

**Files:**
- Modify: `lib/config_loader.rb`
- Modify: `test/test_config_loader.rb`

- [ ] **Step 1: Add new config tests**

Append to `test/test_config_loader.rb` (before the final `end`):

```ruby
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
    yaml = valid_fritz_yaml.sub(/^fritz_box:.*\n(  .*\n){3}/m, "")
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
    yaml = valid_yaml.sub("        host: 192.168.1.192\n", "")
    err = assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
    assert_match(/host.*required/i, err.message)
  end

  def test_rejects_invalid_driver
    yaml = valid_yaml.sub("        host: 192.168.1.192",
                           "        host: 192.168.1.192\n        driver: zigbee")
    err = assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
    assert_match(/driver/i, err.message)
  end
```

- [ ] **Step 2: Run the new tests — expect failures**

```bash
bundle exec ruby -Itest -Ilib test/test_config_loader.rb
```

Expected: 6 new tests fail with `NoMethodError` or `ArgumentError`.

- [ ] **Step 3: Update config_loader.rb**

Replace the full `lib/config_loader.rb` with:

```ruby
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

    ids = []
    plugs = list.map.with_index do |h, i|
      raise Error, "plugs[#{i}] must be a mapping" unless h.is_a?(Hash)
      id = require_string(h["id"], "plugs[#{i}].id")
      raise Error, "plug id '#{id}' must match #{ID_REGEX.source}" unless id =~ ID_REGEX
      raise Error, "duplicate plug id '#{id}'" if ids.include?(id)
      ids << id

      role = require_string(h["role"], "plugs[#{i}].role").to_sym
      raise Error, "plug '#{id}' role must be one of #{VALID_ROLES}" unless VALID_ROLES.include?(role)

      driver = (h["driver"] || "shelly").to_sym
      raise Error, "plug '#{id}' driver must be one of #{VALID_DRIVERS}" unless VALID_DRIVERS.include?(driver)

      name = require_string(h["name"], "plugs[#{i}].name")

      if driver == :shelly
        raise Error, "plugs[#{i}].host is required for driver: shelly" if h["host"].nil? || h["host"].to_s.empty?
        raise Error, "plugs[#{i}].ain must not be set for driver: shelly" if h["ain"]
        PlugCfg.new(id: id, name: name, role: role, driver: :shelly, host: h["host"].to_s, ain: nil)
      else
        raise Error, "plugs[#{i}].ain is required for driver: fritz_dect" if h["ain"].nil? || h["ain"].to_s.empty?
        raise Error, "plugs[#{i}].host must not be set for driver: fritz_dect" if h["host"]
        PlugCfg.new(id: id, name: name, role: role, driver: :fritz_dect, ain: h["ain"].to_s, host: nil)
      end
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

- [ ] **Step 4: Run config loader tests — expect all green**

```bash
bundle exec ruby -Itest -Ilib test/test_config_loader.rb
```

Expected: all tests pass (including the 6 new ones).

- [ ] **Step 5: Run full suite — no regressions**

```bash
bundle exec rake test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/config_loader.rb test/test_config_loader.rb
git commit -m "feat: add fritz_dect driver, ain, and fritz_box config to ConfigLoader"
```

---

## Task 3: Implement FritzDectClient (TDD)

**Files:**
- Create: `test/test_fritz_dect_client.rb`
- Create: `lib/fritz_dect_client.rb`

- [ ] **Step 1: Write the test file**

Create `test/test_fritz_dect_client.rb`:

```ruby
require "test_helper"
require "fritz_dect_client"
require "config_loader"
require "digest"

class FritzDectClientTest < Minitest::Test
  HOST      = "192.168.178.1"
  USER      = "testuser"
  PASSWORD  = "testpass"
  AIN       = "11630 0206224"
  SID       = "abc123def456abcd"
  CHALLENGE = "deadbeef"

  def setup
    @client = FritzDectClient.new(host: HOST, user: USER, password: PASSWORD, timeout: 2)
    @plug   = ConfigLoader::PlugCfg.new(
      id: "krabbencomputer", name: "Test", role: :consumer,
      driver: :fritz_dect, ain: AIN,
    )
  end

  def md5_response
    md5 = Digest::MD5.hexdigest("#{CHALLENGE}-#{PASSWORD}".encode("UTF-16LE").b)
    "#{CHALLENGE}-#{md5}"
  end

  def challenge_xml
    %(<?xml version="1.0"?><SessionInfo><SID>0000000000000000</SID><Challenge>#{CHALLENGE}</Challenge></SessionInfo>)
  end

  def sid_xml
    %(<?xml version="1.0"?><SessionInfo><SID>#{SID}</SID><Challenge>#{CHALLENGE}</Challenge></SessionInfo>)
  end

  def stub_auth
    stub_request(:get, "http://#{HOST}/login_sid.lua")
      .to_return(status: 200, body: challenge_xml)
    stub_request(:get, "http://#{HOST}/login_sid.lua")
      .with(query: hash_including("username" => USER, "response" => md5_response))
      .to_return(status: 200, body: sid_xml)
  end

  def test_parses_successful_response
    stub_auth
    stub_request(:get, "http://#{HOST}/webservices/homeautoswitch.lua")
      .with(query: hash_including("switchcmd" => "getswitchpower", "ain" => AIN, "sid" => SID))
      .to_return(status: 200, body: "342000\n")
    stub_request(:get, "http://#{HOST}/webservices/homeautoswitch.lua")
      .with(query: hash_including("switchcmd" => "getswitchenergy", "ain" => AIN, "sid" => SID))
      .to_return(status: 200, body: "12345\n")

    reading = @client.fetch(@plug)
    assert_in_delta 342.0, reading.apower_w
    assert_in_delta 12_345.0, reading.aenergy_wh
  end

  def test_zero_power_is_valid
    stub_auth
    stub_request(:get, "http://#{HOST}/webservices/homeautoswitch.lua")
      .with(query: hash_including("switchcmd" => "getswitchpower"))
      .to_return(status: 200, body: "0\n")
    stub_request(:get, "http://#{HOST}/webservices/homeautoswitch.lua")
      .with(query: hash_including("switchcmd" => "getswitchenergy"))
      .to_return(status: 200, body: "1000\n")

    reading = @client.fetch(@plug)
    assert_in_delta 0.0, reading.apower_w
  end

  def test_reauths_on_403_and_retries
    stub_auth
    stub_request(:get, "http://#{HOST}/webservices/homeautoswitch.lua")
      .with(query: hash_including("switchcmd" => "getswitchpower"))
      .to_return(status: 403).then
      .to_return(status: 200, body: "100000\n")
    stub_request(:get, "http://#{HOST}/webservices/homeautoswitch.lua")
      .with(query: hash_including("switchcmd" => "getswitchenergy"))
      .to_return(status: 200, body: "5000\n")

    reading = @client.fetch(@plug)
    assert_in_delta 100.0, reading.apower_w
    assert_in_delta 5_000.0, reading.aenergy_wh
  end

  def test_raises_on_permanent_403
    stub_auth
    stub_request(:get, "http://#{HOST}/webservices/homeautoswitch.lua")
      .with(query: hash_including("switchcmd" => "getswitchpower"))
      .to_return(status: 403)

    err = assert_raises(FritzDectClient::Error) { @client.fetch(@plug) }
    assert_match(/403.*re-auth/i, err.message)
  end

  def test_raises_on_auth_failure
    stub_request(:get, "http://#{HOST}/login_sid.lua")
      .to_return(status: 200, body: challenge_xml)
    stub_request(:get, "http://#{HOST}/login_sid.lua")
      .with(query: hash_including("username" => USER))
      .to_return(status: 200,
                 body: %(<?xml version="1.0"?><SessionInfo><SID>0000000000000000</SID></SessionInfo>))

    err = assert_raises(FritzDectClient::Error) { @client.fetch(@plug) }
    assert_match(/authentication failed/i, err.message)
  end

  def test_raises_on_non_200_from_homeauto
    stub_auth
    stub_request(:get, "http://#{HOST}/webservices/homeautoswitch.lua")
      .with(query: hash_including("switchcmd" => "getswitchpower"))
      .to_return(status: 503, body: "")

    assert_raises(FritzDectClient::Error) { @client.fetch(@plug) }
  end

  def test_raises_on_blank_body
    stub_auth
    stub_request(:get, "http://#{HOST}/webservices/homeautoswitch.lua")
      .with(query: hash_including("switchcmd" => "getswitchpower"))
      .to_return(status: 200, body: "")

    assert_raises(FritzDectClient::Error) { @client.fetch(@plug) }
  end

  def test_raises_on_timeout
    stub_request(:get, "http://#{HOST}/login_sid.lua").to_timeout
    assert_raises(FritzDectClient::Error) { @client.fetch(@plug) }
  end

  def test_raises_on_connection_refused
    stub_request(:get, "http://#{HOST}/login_sid.lua").to_raise(Errno::ECONNREFUSED)
    assert_raises(FritzDectClient::Error) { @client.fetch(@plug) }
  end
end
```

- [ ] **Step 2: Run the test — expect LoadError**

```bash
bundle exec ruby -Itest -Ilib test/test_fritz_dect_client.rb
```

Expected: `cannot load such file -- fritz_dect_client`.

- [ ] **Step 3: Create lib/fritz_dect_client.rb**

```ruby
require "net/http"
require "uri"
require "digest"
require "rexml/document"

class FritzDectClient
  class Error < StandardError; end

  Reading = Struct.new(:apower_w, :aenergy_wh, keyword_init: true)

  NETWORK_ERRORS = [
    Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout,
    Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
    Errno::ETIMEDOUT, SocketError, EOFError,
  ].freeze

  def initialize(host:, user:, password:, timeout: 2)
    @host     = host
    @user     = user
    @password = password
    @timeout  = timeout
    @sid      = nil
  end

  def fetch(plug)
    authenticate! if @sid.nil?
    power_mw  = fetch_value(plug.ain, "getswitchpower")
    energy_wh = fetch_value(plug.ain, "getswitchenergy")
    Reading.new(apower_w: power_mw / 1000.0, aenergy_wh: energy_wh.to_f)
  rescue *NETWORK_ERRORS => e
    raise Error, "#{e.class}: #{e.message}"
  end

  private

  def fetch_value(ain, cmd)
    response = get_homeauto(ain, cmd)
    if response.code == "403"
      @sid = nil
      authenticate!
      response = get_homeauto(ain, cmd)
      raise Error, "HTTP 403 from #{@host} after re-auth" if response.code == "403"
    end
    raise Error, "HTTP #{response.code} from #{@host}" unless response.is_a?(Net::HTTPSuccess)
    body = response.body.to_s.strip
    raise Error, "blank response from #{@host}" if body.empty?
    begin
      Integer(body)
    rescue ArgumentError
      raise Error, "unexpected response from #{@host}: #{body}"
    end
  end

  def get_homeauto(ain, cmd)
    uri = URI("http://#{@host}/webservices/homeautoswitch.lua")
    uri.query = URI.encode_www_form(switchcmd: cmd, ain: ain, sid: @sid)
    get(uri)
  end

  def authenticate!
    uri = URI("http://#{@host}/login_sid.lua")
    response = get(uri)
    raise Error, "HTTP #{response.code} during auth" unless response.is_a?(Net::HTTPSuccess)
    doc = REXML::Document.new(response.body)
    challenge = doc.elements["SessionInfo/Challenge"]&.text
    raise Error, "no challenge in auth response" if challenge.nil?

    md5 = Digest::MD5.hexdigest("#{challenge}-#{@password}".encode("UTF-16LE").b)
    uri.query = URI.encode_www_form(username: @user, response: "#{challenge}-#{md5}")
    response = get(uri)
    raise Error, "HTTP #{response.code} during auth" unless response.is_a?(Net::HTTPSuccess)
    doc = REXML::Document.new(response.body)
    sid = doc.elements["SessionInfo/SID"]&.text
    raise Error, "authentication failed for user #{@user}" if sid.nil? || sid == "0000000000000000"
    @sid = sid
  end

  def get(uri)
    Net::HTTP.start(uri.host, uri.port,
                    open_timeout: @timeout, read_timeout: @timeout) do |http|
      http.request(Net::HTTP::Get.new(uri.request_uri))
    end
  end
end
```

- [ ] **Step 4: Run the fritz_dect tests — expect all green**

```bash
bundle exec ruby -Itest -Ilib test/test_fritz_dect_client.rb
```

Expected: 9 tests, 0 failures.

- [ ] **Step 5: Run full suite — no regressions**

```bash
bundle exec rake test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/fritz_dect_client.rb test/test_fritz_dect_client.rb
git commit -m "feat: add FritzDectClient with lazy SID auth"
```

---

## Task 4: Update Poller to use a clients hash

**Files:**
- Modify: `lib/poller.rb`
- Modify: `test/test_poller.rb`

- [ ] **Step 1: Update test_poller.rb**

Replace the full `test/test_poller.rb`:

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
      ConfigLoader::PlugCfg.new(id: "bkw",    name: "BKW",    role: :producer, driver: :shelly, host: "10.0.0.1"),
      ConfigLoader::PlugCfg.new(id: "fridge",  name: "Fridge", role: :consumer, driver: :shelly, host: "10.0.0.2"),
    ]

    @poller = Poller.new(
      plugs:        @plugs,
      db:           @db,
      clients:      @plugs.to_h { |p| [p.id, fake_client] },
      logger:       @logger,
      breaker_opts: { threshold: 3, probe_seconds: 30 },
      clock:        -> { @now },
    )
  end

  def fake_client
    client = Object.new
    def client.fetch(plug) = ShellyClient::Reading.new(apower_w: 100.0, aenergy_wh: 500.0)
    client
  end

  def failing_client(id_to_fail)
    client = Object.new
    client.define_singleton_method(:fetch) do |plug|
      raise ShellyClient::Error, "boom" if plug.id == id_to_fail
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
    failing = failing_client("bkw")
    @poller = Poller.new(
      plugs:        @plugs,
      db:           @db,
      clients:      @plugs.to_h { |p| [p.id, failing] },
      logger:       @logger,
      breaker_opts: { threshold: 3, probe_seconds: 30 },
      clock:        -> { @now },
    )
    @poller.tick
    assert_equal 1, @db[:samples].count
    assert_equal "fridge", @db[:samples].first[:plug_id]
  end

  def test_breaker_opens_after_threshold
    failing = failing_client("bkw")
    @poller = Poller.new(
      plugs:        @plugs,
      db:           @db,
      clients:      @plugs.to_h { |p| [p.id, failing] },
      logger:       @logger,
      breaker_opts: { threshold: 3, probe_seconds: 30 },
      clock:        -> { @now },
    )
    3.times { @poller.tick }
    assert_match(/opening breaker.*bkw/i, @log_io.string)
  end

  def test_only_logs_state_changes
    failing = failing_client("bkw")
    @poller = Poller.new(
      plugs:        @plugs,
      db:           @db,
      clients:      @plugs.to_h { |p| [p.id, failing] },
      logger:       @logger,
      breaker_opts: { threshold: 3, probe_seconds: 30 },
      clock:        -> { @now },
    )
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

```bash
bundle exec ruby -Itest -Ilib test/test_poller.rb
```

Expected: failures because `Poller.new` doesn't accept `clients:` yet.

- [ ] **Step 3: Update lib/poller.rb**

Replace the full `lib/poller.rb`:

```ruby
require "shelly_client"
require "fritz_dect_client"
require "circuit_breaker"

class Poller
  def initialize(plugs:, db:, clients:, logger:, breaker_opts:, clock: -> { Time.now.to_f })
    @plugs    = plugs
    @db       = db
    @clients  = clients
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
        reading = @clients[plug.id].fetch(plug)
        @db[:samples].insert(
          plug_id:    plug.id,
          ts:         ts,
          apower_w:   reading.apower_w,
          aenergy_wh: reading.aenergy_wh,
        )
        breaker.record_success
      rescue ShellyClient::Error, FritzDectClient::Error => e
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

- [ ] **Step 4: Run poller tests — expect all green**

```bash
bundle exec ruby -Itest -Ilib test/test_poller.rb
```

Expected: 5 tests, 0 failures.

- [ ] **Step 5: Run full suite — no regressions**

```bash
bundle exec rake test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/poller.rb test/test_poller.rb
git commit -m "refactor: Poller uses clients hash; rescue FritzDectClient::Error"
```

---

## Task 5: Wire up clients in ziwoas.rb

**Files:**
- Modify: `lib/ziwoas.rb`

- [ ] **Step 1: Update ziwoas.rb**

Replace the full `lib/ziwoas.rb`:

```ruby
require "logger"
require "tzinfo"
require "config_loader"
require "db"
require "shelly_client"
require "fritz_dect_client"
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

      shelly_client = ShellyClient.new(timeout: @config.poll.timeout_seconds)
      fritz_client  = if @config.fritz_box
                        FritzDectClient.new(
                          host:     @config.fritz_box.host,
                          user:     @config.fritz_box.user,
                          password: @config.fritz_box.password,
                          timeout:  @config.poll.timeout_seconds,
                        )
                      end
      clients = @config.plugs.to_h do |plug|
        [plug.id, plug.driver == :fritz_dect ? fritz_client : shelly_client]
      end

      @poller = Poller.new(
        plugs:        @config.plugs,
        db:           @db,
        clients:      clients,
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

      @poller_thread     = spawn_thread("poller")     { @poller.run(@config.poll.interval_seconds) }
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

- [ ] **Step 2: Run full suite**

```bash
bundle exec rake test
```

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add lib/ziwoas.rb
git commit -m "feat: wire FritzDectClient into App startup"
```

---

## Task 6: Update example config

**Files:**
- Modify: `config/ziwoas.example.yml`

- [ ] **Step 1: Update the example file**

Replace the full `config/ziwoas.example.yml`:

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

# Required when any plug uses driver: fritz_dect.
# fritz_box:
#   host: 192.168.178.1
#   user: fritz6584       # Fritz!Box username
#   password: secret      # Fritz!Box password

plugs:
  - id: bkw
    name: Balkonkraftwerk
    role: producer
    host: 192.168.1.192   # Shelly plug (driver defaults to shelly)

  # Shelly consumer example:
  # - id: kuehlschrank
  #   name: Kühlschrank
  #   role: consumer
  #   host: 192.168.1.201

  # Fritz!DECT consumer example (AIN from Fritz!Box device list):
  # - id: krabbencomputer
  #   name: Krabbencomputer
  #   role: consumer
  #   driver: fritz_dect
  #   ain: "11630 0206224"
```

- [ ] **Step 2: Run full suite — final check**

```bash
bundle exec rake test
```

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add config/ziwoas.example.yml
git commit -m "docs: add fritz_box and fritz_dect plug examples to ziwoas.example.yml"
```

# Solakon One – Null-Einspeisung Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die Solakon One per Modbus TCP minütlich so regeln, dass ihre AC-Ausgabe dem aus Shelly-/Fritz-Steckdosen gemessenen Hausverbrauch folgt und damit nie ins Netz einspeist.

**Architecture:** Vier kleine Kollaborateure im Stil des Repos: `SolakonClient` (Modbus-Wrapper, lib/), `ConsumptionReader` (gemessener Verbrauch + export-sicherer Floor, app/models/), `ZeroExportController` (reine Regel-Logik, app/models/), `ZeroExportTickJob` (minütlicher Solid-Queue-Job, verdrahtet alles und loggt). Konfiguration über neuen `solakon:`-Block in `ConfigLoader`.

**Tech Stack:** Ruby/Rails 8.1, Solid Queue (recurring), Minitest, neues Gem `rmodbus` (Modbus TCP). Spec: `docs/superpowers/specs/2026-06-16-solakon-nulleinspeisung-design.md`.

---

## Dateistruktur

| Datei | Verantwortung |
|---|---|
| `Gemfile` | `rmodbus`-Abhängigkeit |
| `lib/solakon_client.rb` (neu) | Modbus-TCP: Zustand lesen, Sollwert/Modus/Min-SoC schreiben |
| `lib/config_loader.rb` (ändern) | `SolakonCfg` + `build_solakon` + Config-Feld |
| `app/models/consumption_reader.rb` (neu) | Σ frische Consumer-Samples + `guaranteed_floor_w` |
| `app/models/zero_export_controller.rb` (neu) | Reine Regel-Logik + Konstanten `MAX_OUTPUT_W`, `MIN_SOC_PCT` |
| `app/jobs/zero_export_tick_job.rb` (neu) | Minütlicher Tick: verdrahten + loggen |
| `config/recurring.yml` (ändern) | `zero_export_tick` jede Minute |
| `config/ziwoas.example.yml` (ändern) | Beispiel-`solakon:`-Block |
| `test/solakon_client_test.rb` (neu) | Modbus-Encode/Decode + Fehlerpfade |
| `test/config_loader_test.rb` (ändern) | `solakon:`-Parsing |
| `test/models/consumption_reader_test.rb` (neu) | Frische-Filter + Floor |
| `test/models/zero_export_controller_test.rb` (neu) | clamp/floor/max/negativ |
| `test/jobs/zero_export_tick_job_test.rb` (neu) | Verdrahtung, Logging, No-Op |

---

## Task 1: Modbus-Register verifizieren & `rmodbus` ergänzen

Die im Spec genannten Registeradressen stammen aus einer Zusammenfassung und MÜSSEN gegen die Quelle bestätigt werden, bevor wir darauf bauen.

**Files:**
- Modify: `Gemfile`

- [ ] **Step 1: Register-Plan gegen die Quelle bestätigen**

Öffne `custom_components/solakon_one/const.py` aus `github.com/solakon-de/solakon-one-homeassistant` und bestätige bzw. korrigiere folgende Werte. Trage Abweichungen in Task 2 nach.

| Zweck | erwartete Adresse | Typ | Notiz |
|---|---|---|---|
| Remote Control (Modus-Enable) | 46001 | u16 (holding) | **Wert zum Aktivieren der Fernsteuerung notieren → `REMOTE_CONTROL_ENABLE`** |
| Remote Active Power (Sollwert) | 46003 | i32 (holding, 2 Regs) | W |
| Minimum SOC | 46609 | u16 (holding) | % |
| Battery SOC | 39424 | i16 (input) | % |
| Active Power | 39134 | i32 (input, 2 Regs) | W |
| Total PV Power | 39118 | i32 (input, 2 Regs) | W |
| Battery Power | 39230 | i32 (input, 2 Regs) | W |

Zusätzlich klären (in pymodbus der Integration nachsehen):
- **Adressierung:** Wird die Adresse direkt (z. B. 46003) an pymodbus übergeben, oder mit 4xxxx-Offset (−40001)? `rmodbus` erwartet dieselbe rohe Adresse wie pymodbus → übernehmen wie dort.
- **Wortreihenfolge i32:** big-endian (High-Word zuerst) oder little-endian? Default in diesem Plan ist **big-endian** (High zuerst). Falls die Quelle little-endian nutzt, in Task 2 die Helper `to_i32`/`from_i32` die Word-Reihenfolge tauschen.

- [ ] **Step 2: Gem ergänzen**

In `Gemfile`, hinter der `mqtt`-Zeile am Dateiende:

```ruby
gem "mqtt"
gem "rmodbus"
```

- [ ] **Step 3: Installieren**

Run: `bundle install`
Expected: `rmodbus` wird aufgelöst und installiert; `Gemfile.lock` aktualisiert.

- [ ] **Step 4: Commit**

```bash
git add Gemfile Gemfile.lock
git commit -m "build: add rmodbus for Solakon Modbus TCP control"
```

---

## Task 2: `SolakonClient` (Modbus-Wrapper)

**Files:**
- Create: `lib/solakon_client.rb`
- Test: `test/solakon_client_test.rb`

- [ ] **Step 1: Failing test schreiben**

`test/solakon_client_test.rb`:

```ruby
require "test_helper"
require "solakon_client"

class SolakonClientTest < Minitest::Test
  class FakeSlave
    attr_reader :writes
    def initialize(inputs: {})
      @inputs = inputs
      @writes = []
    end

    def read_input_registers(addr, count) = @inputs.fetch([ addr, count ])
    def write_holding_register(addr, val) = (@writes << [ :single, addr, val ])
    def write_holding_registers(addr, vals) = (@writes << [ :multi, addr, vals ])
  end

  def client_for(slave)
    SolakonClient.new(host: "h", open: ->(&blk) { blk.call(slave) })
  end

  def test_read_state_decodes_signed_values
    slave = FakeSlave.new(inputs: {
      [ 39424, 1 ] => [ 55 ],               # soc 55 %
      [ 39134, 2 ] => [ 0x0000, 0x012C ],   # active 300 W
      [ 39118, 2 ] => [ 0x0000, 0x0064 ],   # pv 100 W
      [ 39230, 2 ] => [ 0xFFFF, 0xFF38 ],   # battery -200 W (laden)
    })
    state = client_for(slave).read_state
    assert_equal 55, state.battery_soc
    assert_equal 300, state.active_power_w
    assert_equal 100, state.pv_power_w
    assert_equal(-200, state.battery_power_w)
  end

  def test_write_output_power_encodes_i32_big_endian
    slave = FakeSlave.new
    client_for(slave).write_output_power!(300)
    assert_equal [ :multi, 46003, [ 0x0000, 0x012C ] ], slave.writes.first
  end

  def test_write_output_power_encodes_negative
    slave = FakeSlave.new
    client_for(slave).write_output_power!(-200)
    assert_equal [ :multi, 46003, [ 0xFFFF, 0xFF38 ] ], slave.writes.first
  end

  def test_ensure_helpers_write_single_registers
    slave = FakeSlave.new
    c = client_for(slave)
    c.ensure_remote_control!
    c.ensure_minimum_soc!(10)
    assert_includes slave.writes, [ :single, 46001, SolakonClient::REMOTE_CONTROL_ENABLE ]
    assert_includes slave.writes, [ :single, 46609, 10 ]
  end

  def test_errors_are_wrapped
    failing = Object.new
    def failing.read_input_registers(*) = raise("boom")
    client = SolakonClient.new(host: "h", open: ->(&blk) { blk.call(failing) })
    assert_raises(SolakonClient::Error) { client.read_state }
  end
end
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag prüfen**

Run: `bin/rails test test/solakon_client_test.rb`
Expected: FAIL (`cannot load such file -- solakon_client`).

- [ ] **Step 3: Implementieren**

`lib/solakon_client.rb`:

```ruby
require "rmodbus"

# Thin Modbus-TCP wrapper for the Solakon One inverter.
# Register addresses come from solakon-de/solakon-one-homeassistant
# (custom_components/solakon_one/const.py) — see Task 1 verification.
class SolakonClient
  class Error < StandardError; end

  # Holding registers (read/write)
  REG_REMOTE_CONTROL      = 46001 # u16 – control-mode enable
  REG_REMOTE_ACTIVE_POWER = 46003 # i32 – setpoint W (2 regs)
  REG_MINIMUM_SOC         = 46609 # u16 – %

  # Input registers (read-only)
  REG_BATTERY_SOC   = 39424 # i16 – %
  REG_ACTIVE_POWER  = 39134 # i32 – W (2 regs)
  REG_PV_POWER      = 39118 # i32 – W (2 regs)
  REG_BATTERY_POWER = 39230 # i32 – W (2 regs)

  # Value written to REG_REMOTE_CONTROL to enable remote active-power control.
  # Confirm against const.py in Task 1.
  REMOTE_CONTROL_ENABLE = 1

  State = Struct.new(:battery_soc, :active_power_w, :pv_power_w, :battery_power_w,
                     keyword_init: true)

  def initialize(host:, port: 502, unit_id: 1, open: nil)
    @host    = host
    @port    = port
    @unit_id = unit_id
    @open    = open || method(:default_open)
  end

  def read_state
    with_slave do |slave|
      State.new(
        battery_soc:     to_i16(slave.read_input_registers(REG_BATTERY_SOC, 1).first),
        active_power_w:  to_i32(slave.read_input_registers(REG_ACTIVE_POWER, 2)),
        pv_power_w:      to_i32(slave.read_input_registers(REG_PV_POWER, 2)),
        battery_power_w: to_i32(slave.read_input_registers(REG_BATTERY_POWER, 2)),
      )
    end
  end

  def write_output_power!(watts)
    with_slave { |slave| slave.write_holding_registers(REG_REMOTE_ACTIVE_POWER, from_i32(watts.to_i)) }
  end

  def ensure_remote_control!
    with_slave { |slave| slave.write_holding_register(REG_REMOTE_CONTROL, REMOTE_CONTROL_ENABLE) }
  end

  def ensure_minimum_soc!(pct)
    with_slave { |slave| slave.write_holding_register(REG_MINIMUM_SOC, pct.to_i) }
  end

  private

  def default_open(&blk)
    ModBus::TCPClient.connect(@host, @port) do |client|
      client.with_slave(@unit_id) { |slave| blk.call(slave) }
    end
  end

  def with_slave(&blk)
    @open.call(&blk)
  rescue Error
    raise
  rescue StandardError => e
    raise Error, "#{e.class}: #{e.message}"
  end

  # Big-endian word order: [high, low]
  def to_i32(regs)
    raw = ((regs[0] & 0xFFFF) << 16) | (regs[1] & 0xFFFF)
    raw >= 0x8000_0000 ? raw - 0x1_0000_0000 : raw
  end

  def from_i32(value)
    raw = value.negative? ? value + 0x1_0000_0000 : value
    [ (raw >> 16) & 0xFFFF, raw & 0xFFFF ]
  end

  def to_i16(reg)
    reg >= 0x8000 ? reg - 0x1_0000 : reg
  end
end
```

- [ ] **Step 4: Test laufen lassen, Erfolg prüfen**

Run: `bin/rails test test/solakon_client_test.rb`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/solakon_client.rb test/solakon_client_test.rb
git commit -m "feat: add SolakonClient Modbus TCP wrapper"
```

---

## Task 3: `ConfigLoader` – `solakon:`-Block

**Files:**
- Modify: `lib/config_loader.rb`
- Test: `test/config_loader_test.rb`

- [ ] **Step 1: Failing test ergänzen**

In `test/config_loader_test.rb` neue Tests hinzufügen (am Ende der Klasse, vor dem schließenden `end`):

```ruby
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
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag prüfen**

Run: `bin/rails test test/config_loader_test.rb -n /solakon/`
Expected: FAIL (`undefined method 'solakon'`).

- [ ] **Step 3: Implementieren**

In `lib/config_loader.rb` den Struct ergänzen (bei den anderen Structs oben):

```ruby
  SolakonCfg   = Struct.new(:host, :port, :unit_id, :enabled, :stale_after_s, keyword_init: true)
```

Im `Config = Struct.new(...)` die Liste um `:solakon` erweitern:

```ruby
  Config       = Struct.new(:electricity_price_eur_per_kwh, :timezone,
                            :mqtt, :fritz_poll, :plugs, :fritz_box, :weather,
                            :switchbot, :sensors, :trmnl, :solakon,
                            keyword_init: true)
```

In `#build` die Variable bauen (neben den anderen `build_*`-Aufrufen):

```ruby
    solakon = build_solakon(@raw["solakon"])
```

Und im `Config.new(...)`-Aufruf ergänzen:

```ruby
      trmnl: trmnl,
      solakon: solakon,
    )
```

Die private Builder-Methode hinzufügen (bei den anderen `build_*`-Methoden):

```ruby
  def build_solakon(h)
    return nil if h.nil?
    h = require_hash(h, "solakon")
    SolakonCfg.new(
      host:          require_string(h["host"], "solakon.host"),
      port:          (h["port"] || 502).to_i,
      unit_id:       (h["unit_id"] || 1).to_i,
      enabled:       h.key?("enabled") ? !!h["enabled"] : true,
      stale_after_s: (h["stale_after_s"] || 120).to_i,
    )
  end
```

- [ ] **Step 4: Test laufen lassen, Erfolg prüfen**

Run: `bin/rails test test/config_loader_test.rb`
Expected: PASS (alle, inkl. der 4 neuen).

- [ ] **Step 5: Commit**

```bash
git add lib/config_loader.rb test/config_loader_test.rb
git commit -m "feat: parse solakon config block"
```

---

## Task 4: `ConsumptionReader`

**Files:**
- Create: `app/models/consumption_reader.rb`
- Test: `test/models/consumption_reader_test.rb`

- [ ] **Step 1: Failing test schreiben**

`test/models/consumption_reader_test.rb`:

```ruby
require "test_helper"

class ConsumptionReaderTest < ActiveSupport::TestCase
  Plug = Struct.new(:id, :role, keyword_init: true)

  def plugs
    [ Plug.new(id: "bkw",    role: :producer),
      Plug.new(id: "fridge", role: :consumer),
      Plug.new(id: "tv",     role: :consumer) ]
  end

  setup { Sample.delete_all }

  test "current_consumption_w sums latest fresh consumer samples, ignores producer" do
    now = Time.at(1_000_000)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 10, apower_w: 100, aenergy_wh: 1)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 5,  apower_w: 120, aenergy_wh: 1) # latest wins
    Sample.create!(plug_id: "tv",     ts: now.to_i - 5,  apower_w: 30,  aenergy_wh: 1)
    Sample.create!(plug_id: "bkw",    ts: now.to_i - 5,  apower_w: 500, aenergy_wh: 1) # producer, ignored
    reader = ConsumptionReader.new(plugs: plugs, now: now, stale_after_s: 120)
    assert_in_delta 150.0, reader.current_consumption_w
  end

  test "current_consumption_w drops stale samples" do
    now = Time.at(1_000_000)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 5,   apower_w: 120, aenergy_wh: 1)
    Sample.create!(plug_id: "tv",     ts: now.to_i - 300, apower_w: 30,  aenergy_wh: 1) # stale
    reader = ConsumptionReader.new(plugs: plugs, now: now, stale_after_s: 120)
    assert_in_delta 120.0, reader.current_consumption_w
  end

  test "guaranteed_floor_w is the minimum 5-min total over 24h" do
    now = Time.at(1_000_000)
    # bucket A (low total = 100): -1000s
    Sample.create!(plug_id: "fridge", ts: now.to_i - 1000, apower_w: 100, aenergy_wh: 1)
    Sample.create!(plug_id: "tv",     ts: now.to_i - 1000, apower_w: 0,   aenergy_wh: 1)
    # bucket B (high total = 300, 15 min later): -100s
    Sample.create!(plug_id: "fridge", ts: now.to_i - 100,  apower_w: 200, aenergy_wh: 1)
    Sample.create!(plug_id: "tv",     ts: now.to_i - 100,  apower_w: 100, aenergy_wh: 1)
    reader = ConsumptionReader.new(plugs: plugs, now: now)
    assert_in_delta 100.0, reader.guaranteed_floor_w
  end

  test "guaranteed_floor_w ignores samples older than 24h" do
    now = Time.at(1_000_000)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 100,        apower_w: 250, aenergy_wh: 1)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 90_000,     apower_w: 10,  aenergy_wh: 1) # >24h
    reader = ConsumptionReader.new(plugs: plugs, now: now)
    assert_in_delta 250.0, reader.guaranteed_floor_w
  end

  test "zero when no consumer plugs" do
    reader = ConsumptionReader.new(plugs: [], now: Time.at(1_000_000))
    assert_equal 0.0, reader.current_consumption_w
    assert_equal 0.0, reader.guaranteed_floor_w
  end
end
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag prüfen**

Run: `bin/rails test test/models/consumption_reader_test.rb`
Expected: FAIL (`uninitialized constant ConsumptionReader`).

- [ ] **Step 3: Implementieren**

`app/models/consumption_reader.rb`:

```ruby
# Reads current measured household consumption from Shelly/Fritz samples
# and computes the export-safe lower bound (guaranteed_floor_w).
class ConsumptionReader
  FLOOR_WINDOW_S = 24 * 60 * 60
  BUCKET_S       = 300

  def initialize(plugs:, now: Time.now, stale_after_s: 120)
    @consumer_ids  = plugs.select { |p| p.role == :consumer }.map(&:id)
    @now           = now
    @stale_after_s = stale_after_s
  end

  # Sum of the latest fresh apower_w across consumer plugs.
  def current_consumption_w
    return 0.0 if @consumer_ids.empty?
    now_ts = @now.to_i
    Sample
      .where(plug_id: @consumer_ids)
      .where("(plug_id, ts) IN (SELECT plug_id, MAX(ts) FROM samples WHERE plug_id IN (?) GROUP BY plug_id)", @consumer_ids)
      .select { |s| (now_ts - s.ts) <= @stale_after_s }
      .sum(&:apower_w)
  end

  # Minimum total 5-min consumption over the last 24h. Computed from raw
  # samples because samples_5min is only built daily by the Aggregator.
  def guaranteed_floor_w
    return 0.0 if @consumer_ids.empty?
    cutoff = @now.to_i - FLOOR_WINDOW_S
    rows = Sample
      .where(plug_id: @consumer_ids)
      .where("ts >= ?", cutoff)
      .group("plug_id", Arel.sql("(ts / #{BUCKET_S}) * #{BUCKET_S}"))
      .select("plug_id", Arel.sql("(ts / #{BUCKET_S}) * #{BUCKET_S} AS bucket_ts"), Arel.sql("AVG(apower_w) AS avg_w"))

    totals = Hash.new(0.0)
    rows.each { |r| totals[r.bucket_ts] += r.avg_w.to_f }
    totals.empty? ? 0.0 : totals.values.min
  end
end
```

- [ ] **Step 4: Test laufen lassen, Erfolg prüfen**

Run: `bin/rails test test/models/consumption_reader_test.rb`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add app/models/consumption_reader.rb test/models/consumption_reader_test.rb
git commit -m "feat: add ConsumptionReader for measured load and export-safe floor"
```

---

## Task 5: `ZeroExportController` (reine Regel-Logik)

**Files:**
- Create: `app/models/zero_export_controller.rb`
- Test: `test/models/zero_export_controller_test.rb`

- [ ] **Step 1: Failing test schreiben**

`test/models/zero_export_controller_test.rb`:

```ruby
require "test_helper"

class ZeroExportControllerTest < Minitest::Test
  def test_target_follows_consumption_when_above_floor
    assert_equal 250, ZeroExportController.target_output_w(consumption_w: 250.4, floor_w: 100)
  end

  def test_floor_is_lower_bound
    assert_equal 100, ZeroExportController.target_output_w(consumption_w: 40, floor_w: 100)
  end

  def test_capped_at_max_output
    assert_equal 800, ZeroExportController.target_output_w(consumption_w: 1500, floor_w: 100)
  end

  def test_never_negative
    assert_equal 0, ZeroExportController.target_output_w(consumption_w: -50, floor_w: -10)
  end

  def test_constants
    assert_equal 800, ZeroExportController::MAX_OUTPUT_W
    assert_equal 10, ZeroExportController::MIN_SOC_PCT
  end
end
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag prüfen**

Run: `bin/rails test test/models/zero_export_controller_test.rb`
Expected: FAIL (`uninitialized constant ZeroExportController`).

- [ ] **Step 3: Implementieren**

`app/models/zero_export_controller.rb`:

```ruby
# Pure control law for zero-export: choose the inverter AC setpoint so that
# output never exceeds measured household load (which guarantees no export).
class ZeroExportController
  MAX_OUTPUT_W = 800 # legal balcony-PV feed limit
  MIN_SOC_PCT  = 10  # never discharge the battery below this

  # floor_w is an export-safe lower bound; consumption_w is the live measured
  # load. The higher of the two, clamped to [0, MAX_OUTPUT_W].
  def self.target_output_w(consumption_w:, floor_w:)
    [ consumption_w, floor_w, 0.0 ].max.clamp(0, MAX_OUTPUT_W).round
  end
end
```

- [ ] **Step 4: Test laufen lassen, Erfolg prüfen**

Run: `bin/rails test test/models/zero_export_controller_test.rb`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add app/models/zero_export_controller.rb test/models/zero_export_controller_test.rb
git commit -m "feat: add ZeroExportController control law"
```

---

## Task 6: `ZeroExportTickJob` (minütlicher Tick)

**Files:**
- Create: `app/jobs/zero_export_tick_job.rb`
- Test: `test/jobs/zero_export_tick_job_test.rb`

- [ ] **Step 1: Failing test schreiben**

`test/jobs/zero_export_tick_job_test.rb`:

```ruby
require "test_helper"

class ZeroExportTickJobTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :writes
    def initialize(state: nil)
      @state  = state
      @writes = []
    end

    def ensure_remote_control!     = (@writes << :remote)
    def ensure_minimum_soc!(pct)   = (@writes << [ :min_soc, pct ])
    def write_output_power!(watts) = (@writes << [ :power, watts ])
    def read_state                 = @state
  end

  Plug = Struct.new(:id, :role, :name, keyword_init: true)
  Sol  = Struct.new(:host, :port, :unit_id, :enabled, :stale_after_s, keyword_init: true)
  Cfg  = Struct.new(:plugs, :solakon, keyword_init: true)

  def config(enabled: true, solakon: true)
    sol = solakon ? Sol.new(host: "h", port: 502, unit_id: 1, enabled: enabled, stale_after_s: 120) : nil
    Cfg.new(plugs: [ Plug.new(id: "fridge", role: :consumer, name: "Kühlschrank") ], solakon: sol)
  end

  setup do
    Sample.delete_all
    Rails.cache.clear
  end

  test "writes target derived from measured consumption" do
    now = Time.at(1_000_000)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 5, apower_w: 250, aenergy_wh: 1)
    client = FakeClient.new(state: SolakonClient::State.new(
      battery_soc: 55, active_power_w: 250, pv_power_w: 0, battery_power_w: 0))

    ConfigLoader.stub(:app_config, config) do
      ZeroExportTickJob.new.perform(client: client, reader_now: now)
    end

    assert_includes client.writes, :remote
    assert_includes client.writes, [ :min_soc, 10 ]
    assert_includes client.writes, [ :power, 250 ]
  end

  test "no-op when disabled" do
    client = FakeClient.new
    ConfigLoader.stub(:app_config, config(enabled: false)) do
      ZeroExportTickJob.new.perform(client: client, reader_now: Time.now)
    end
    assert_empty client.writes
  end

  test "no-op when solakon not configured" do
    client = FakeClient.new
    ConfigLoader.stub(:app_config, config(solakon: false)) do
      ZeroExportTickJob.new.perform(client: client, reader_now: Time.now)
    end
    assert_empty client.writes
  end

  test "swallows Modbus errors" do
    now = Time.at(1_000_000)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 5, apower_w: 250, aenergy_wh: 1)
    client = FakeClient.new
    def client.ensure_remote_control! = raise(SolakonClient::Error, "down")

    ConfigLoader.stub(:app_config, config) do
      assert_nothing_raised do
        ZeroExportTickJob.new.perform(client: client, reader_now: now)
      end
    end
  end
end
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag prüfen**

Run: `bin/rails test test/jobs/zero_export_tick_job_test.rb`
Expected: FAIL (`uninitialized constant ZeroExportTickJob`).

- [ ] **Step 3: Implementieren**

`app/jobs/zero_export_tick_job.rb`:

```ruby
require "config_loader"
require "solakon_client"

class ZeroExportTickJob < ApplicationJob
  queue_as :default

  FLOOR_CACHE_KEY = "zero_export.floor_w".freeze

  def perform(client: nil, reader_now: Time.now)
    config  = ConfigLoader.app_config
    solakon = config.solakon
    return Rails.logger.info("zero_export: not configured") if solakon.nil?
    return Rails.logger.info("zero_export: disabled")       unless solakon.enabled

    reader = ConsumptionReader.new(plugs: config.plugs, now: reader_now,
                                   stale_after_s: solakon.stale_after_s)
    floor       = Rails.cache.fetch(FLOOR_CACHE_KEY, expires_in: 1.hour) { reader.guaranteed_floor_w }
    consumption = reader.current_consumption_w
    target      = ZeroExportController.target_output_w(consumption_w: consumption, floor_w: floor)

    client ||= SolakonClient.new(host: solakon.host, port: solakon.port, unit_id: solakon.unit_id)

    begin
      client.ensure_remote_control!
      client.ensure_minimum_soc!(ZeroExportController::MIN_SOC_PCT)
      client.write_output_power!(target)
      state = client.read_state
      Rails.logger.info(
        "zero_export: consumption=#{consumption.round}W floor=#{floor.round}W target=#{target}W " \
        "soc=#{state.battery_soc}% active=#{state.active_power_w}W " \
        "pv=#{state.pv_power_w}W battery=#{state.battery_power_w}W"
      )
    rescue SolakonClient::Error => e
      Rails.logger.warn("zero_export: Modbus failure (target was #{target}W): #{e.message}")
    end
  end
end
```

- [ ] **Step 4: Test laufen lassen, Erfolg prüfen**

Run: `bin/rails test test/jobs/zero_export_tick_job_test.rb`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add app/jobs/zero_export_tick_job.rb test/jobs/zero_export_tick_job_test.rb
git commit -m "feat: add ZeroExportTickJob wiring reader, controller and Modbus client"
```

---

## Task 7: Scheduling + Beispielkonfiguration verdrahten

**Files:**
- Modify: `config/recurring.yml`
- Modify: `config/ziwoas.example.yml`

- [ ] **Step 1: Recurring-Eintrag ergänzen**

In `config/recurring.yml`, im Block `aggregator_schedule: &aggregator_schedule` (hinter `schedule_tick:`):

```yaml
  zero_export_tick:
    class: ZeroExportTickJob
    queue: default
    schedule: every minute
```

- [ ] **Step 2: Beispielkonfiguration ergänzen**

In `config/ziwoas.example.yml`, hinter dem `mqtt:`-Block:

```yaml
# Solakon One – Null-Einspeisung (Steuerung per Modbus TCP).
# Ohne diesen Block ist die Regelung aus.
# solakon:
#   host: 192.168.1.50      # Modbus-TCP-Host der Solakon One
#   port: 502               # Modbus-TCP-Port (Default 502)
#   unit_id: 1              # Modbus Unit/Slave ID
#   enabled: true           # false schaltet die Regelung ab
#   stale_after_s: 120      # Samples älter als das fallen aus der Live-Summe
```

- [ ] **Step 3: Gesamte Testsuite laufen lassen**

Run: `bin/rails test`
Expected: PASS (alle Tests grün, inkl. der neuen aus Tasks 2–6).

- [ ] **Step 4: Commit**

```bash
git add config/recurring.yml config/ziwoas.example.yml
git commit -m "feat: schedule zero_export_tick every minute and document config"
```

- [ ] **Step 5: Reale Konfiguration setzen (manueller Schritt, kein Commit)**

In `config/ziwoas.yml` (nicht eingecheckt) den `solakon:`-Block mit echten Werten (Host/Unit-ID der Solakon One) ergänzen und `enabled: true` setzen. Logs prüfen: `tail -f log/development.log | grep zero_export`.

---

## Hinweise zur Inbetriebnahme (nach Task 7)

- **Erstes Schreiben vorsichtig beobachten:** Beim ersten echten Lauf die Solakon-Werte (z. B. in HA oder direkt) gegen das Log prüfen — `target` vs. tatsächliches `active`. Insbesondere die i32-Wortreihenfolge (Task 1, Step 1) anhand eines bekannten Werts (z. B. PV-Leistung bei Sonne) verifizieren; bei Unsinn die Word-Reihenfolge in `to_i32`/`from_i32` tauschen.
- **Watchdog (offen aus Spec):** Prüfen, ob `remote_active_power_control` nach Ausbleiben von Befehlen automatisch zurückfällt. Falls nicht, ist ein Fallback (Steuermodus zurücksetzen bei wiederholten Fehlern) ein sinnvoller Folge-PR — für v1 mildert der minütliche Re-Send das Risiko.
```

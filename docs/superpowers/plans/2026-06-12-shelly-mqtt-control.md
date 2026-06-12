# Shelly Plug Control via MQTT — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Schalten" tab that switches Shelly plugs on/off manually and via DB-backed time windows, with edge-triggered scheduling where manual commands win between edges.

**Architecture:** Rails publishes MQTT commands over short-lived connections through a single choke point (`PlugCommander`), triggered either by `PlugSwitchesController` (manual) or a minutely `ScheduleTickJob` (Solid Queue recurring) that computes window edges since a persisted watermark. The existing collector stays read-only; `MqttSubscriber` additionally parses `output` from status messages into `plug_states` and the ActionCable broadcast.

**Tech Stack:** Rails 8.1, SQLite, Solid Queue, Turbo (turbo_stream responses), Stimulus (importmap), ActionCable (solid_cable), `mqtt` gem, Minitest.

**Spec:** `docs/superpowers/specs/2026-06-12-shelly-mqtt-control-design.md`
**Mockups:** `.superpowers/brainstorm/585152-1781243714/content/tab-detail.html`, `tab-layout.html`

---

## Codebase orientation (read this first)

- Config lives in `config/ziwoas.yml`, parsed by `lib/config_loader.rb` into structs (`ConfigLoader::PlugCfg` etc.). Controllers access it via the private `app_config` method on `ApplicationController` (uses `config/ziwoas.test.yml` in tests). Jobs load it themselves (see `app/jobs/sensor_poll_job.rb#load_config`).
- `Time.zone` is already set to the configured IANA timezone (`config/application.rb` reads it from the YAML), so `Time.current` and `Time.zone.local` are in Europe/Berlin.
- `lib/mqtt_subscriber.rb` runs inside `bin/ziwoas_collector` (separate process, full Rails env, DB access works). It already broadcasts batched plug data on the ActionCable `"dashboard"` stream; `app/javascript/controllers/dashboard_controller.js` shows how the frontend consumes it.
- MQTT publishing pattern with injectable client factory: see `lib/fritz_mqtt_bridge.rb` (`mqtt_factory:` kwarg, default `-> { MQTT::Client.new(host:, port:) }`).
- Tests are Minitest. Style: `test "..." do` blocks in `ActiveSupport::TestCase`/`ActionDispatch::IntegrationTest`. Run a single file with `rtk bin/rails test test/path/file_test.rb`. There are no fixture files for data tables (`test/fixtures/` only contains `files/`), so create records in `setup`/tests and `delete_all` first when counting.
- Recurring jobs: `config/recurring.yml` with a shared YAML anchor for development+production.
- CSS: single file `app/assets/stylesheets/application.css` with vars `--accent: #f59f00`, `--online: #40c057`, `--offline: #adb5bd`, `--card`, `--border`, `--muted`. Cards are `border-radius: 12px`, `border: 1px solid var(--border)`.
- Stimulus controllers in `app/javascript/controllers/` are auto-registered by filename (`eagerLoadControllersFrom` in `controllers/index.js`) — `switches_controller.js` becomes `data-controller="switches"`, no manual registration.
- German UI labels, English paths (`/reports` → "Berichte"). Nav lives in `app/views/layouts/application.html.erb`.

## File structure

| File | Responsibility |
|---|---|
| `lib/config_loader.rb` (modify) | parse optional `switchable` plug flag |
| `db/migrate/*_create_switch_tables.rb` (create) | `switch_windows`, `switch_commands`, `plug_states`, `scheduler_states` |
| `app/models/switch_window.rb` (create) | time-window record, validations, `HH:MM` virtual attrs |
| `app/models/switch_command.rb` (create) | command log, `latest_for`, `manual_after?` |
| `app/models/plug_state.rb` (create) | last known output per plug, `record_output` (write only on change) |
| `app/models/scheduler_state.rb` (create) | singleton watermark row |
| `app/models/switch_edge_calculator.rb` (create) | pure edge computation PORO (no I/O) |
| `app/models/plug_commander.rb` (create) | driver dispatch + MQTT publish + command log |
| `app/models/switch_row.rb` (create) | per-plug view model (state, last command, next edge, watt, offline) |
| `app/jobs/schedule_tick_job.rb` (create) | minutely tick: watermark → edges → collapse → manual-wins → publish |
| `config/recurring.yml` (modify) | schedule the tick job every minute |
| `lib/mqtt_subscriber.rb` (modify) | parse `output`, upsert `plug_states`, broadcast `output` |
| `config/routes.rb` (modify) | `/switches`, `POST /plugs/:plug_id/switch`, window CRUD |
| `app/controllers/switches_controller.rb` (create) | tab page |
| `app/controllers/plug_switches_controller.rb` (create) | manual switch endpoint |
| `app/controllers/switch_windows_controller.rb` (create) | window CRUD (turbo_stream) |
| `app/helpers/switches_helper.rb` (create) | status line, weekday/window labels |
| `app/views/switches/*` (create) | index + partials (card, head, windows, window, window_form) |
| `app/javascript/controllers/switches_controller.js` (create) | live updates via ActionCable |
| `app/views/layouts/application.html.erb` (modify) | nav entry "Schalten" |
| `app/assets/stylesheets/application.css` (modify) | `.sw-*` styles |
| `config/ziwoas.test.yml`, `config/ziwoas.example.yml` (modify) | `switchable` flag |

---

### Task 1: `switchable` flag in ConfigLoader

**Files:**
- Modify: `lib/config_loader.rb`
- Modify: `config/ziwoas.test.yml`
- Modify: `config/ziwoas.example.yml`
- Test: `test/test_config_loader.rb`

- [ ] **Step 1: Write the failing tests**

Append inside `class ConfigLoaderTest` in `test/test_config_loader.rb` (this file uses `def test_*` methods and a `load_yaml`/`valid_yaml` helper — see its top):

```ruby
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
```

Note: `valid_yaml` plug entries are indented 4 spaces under `- id:`, hence the `\n    ` in the subs.

- [ ] **Step 2: Run tests to verify they fail**

Run: `rtk bin/rails test test/test_config_loader.rb`
Expected: the 4 new tests FAIL (struct has no `switchable` member → `NoMethodError`, and no validation errors raised).

- [ ] **Step 3: Implement**

In `lib/config_loader.rb`:

1. Extend the struct (line 7):

```ruby
PlugCfg = Struct.new(:id, :name, :role, :ain, :driver, :room, :switchable, keyword_init: true)
```

2. In `PlugValidator#validate!`, after the `driver` check and before `name = ...`, add:

```ruby
switchable = @h.key?("switchable") ? @h["switchable"] : false
unless [ true, false ].include?(switchable)
  raise ConfigLoader::Error, "plugs[#{@index}].switchable must be true or false"
end
if switchable && role == :producer
  raise ConfigLoader::Error, "plug '#{id}' with role: producer cannot be switchable"
end
```

and change the last line of `validate!` to `build_plug(id, name, role, driver, switchable)`.

3. Update `build_plug` to take and pass the flag:

```ruby
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
```

4. In `config/ziwoas.test.yml`, mark the fridge switchable (later controller/job tests rely on this):

```yaml
  - id: fridge
    name: Kühlschrank
    role: consumer
    switchable: true
```

5. In `config/ziwoas.example.yml`, add to one consumer plug entry (with a comment):

```yaml
    # switchable: true   # zeigt den Plug im "Schalten"-Tab (nur Shelly)
```

- [ ] **Step 4: Run the full test suite to verify nothing broke**

Run: `rtk bin/rails test`
Expected: PASS (existing `PlugCfg.new(...)` call sites without `switchable:` still work — keyword_init structs allow missing keys, the member is just `nil`, and `nil` is falsy everywhere we read it).

- [ ] **Step 5: Commit**

```bash
rtk git add lib/config_loader.rb config/ziwoas.test.yml config/ziwoas.example.yml test/test_config_loader.rb
rtk git commit -m "Add switchable flag to plug config"
```

---

### Task 2: Migration for the four switch tables

**Files:**
- Create: `db/migrate/20260612000000_create_switch_tables.rb`

- [ ] **Step 1: Write the migration**

```ruby
class CreateSwitchTables < ActiveRecord::Migration[8.1]
  def change
    create_table :switch_windows do |t|
      t.string  :plug_id, null: false
      t.integer :on_at,   null: false
      t.integer :off_at,  null: false
      t.json    :days,    null: false
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end
    add_index :switch_windows, :plug_id

    create_table :switch_commands do |t|
      t.string :plug_id, null: false
      t.string :action,  null: false
      t.string :source,  null: false
      t.timestamps
    end
    add_index :switch_commands, [ :plug_id, :created_at ]

    create_table :plug_states do |t|
      t.string  :plug_id, null: false
      t.boolean :output,  null: false
      t.timestamps
    end
    add_index :plug_states, :plug_id, unique: true

    create_table :scheduler_states do |t|
      t.datetime :last_tick_at, null: false
      t.timestamps
    end
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `rtk bin/rails db:migrate`
Expected: all four tables created, `db/schema.rb` regenerated to version `2026_06_12_000000`.

- [ ] **Step 3: Verify tests still pass (test DB picks up schema)**

Run: `rtk bin/rails test test/test_smoke.rb`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
rtk git add db/migrate/20260612000000_create_switch_tables.rb db/schema.rb
rtk git commit -m "Add switch_windows, switch_commands, plug_states, scheduler_states tables"
```

---

### Task 3: SwitchWindow model

**Files:**
- Create: `app/models/switch_window.rb`
- Test: `test/models/switch_window_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
require "test_helper"

class SwitchWindowTest < ActiveSupport::TestCase
  def valid_attrs
    { plug_id: "fridge", on_at: 1080, off_at: 1380, days: [ 1, 2, 3, 4, 5 ] }
  end

  test "valid window saves" do
    assert SwitchWindow.new(valid_attrs).valid?
  end

  test "enabled defaults to true" do
    assert SwitchWindow.create!(valid_attrs).enabled
  end

  test "on_at and off_at must be within 0..1439" do
    refute SwitchWindow.new(valid_attrs.merge(on_at: -1)).valid?
    refute SwitchWindow.new(valid_attrs.merge(off_at: 1440)).valid?
  end

  test "on_at must differ from off_at" do
    refute SwitchWindow.new(valid_attrs.merge(on_at: 600, off_at: 600)).valid?
  end

  test "days must be a non-empty list of ISO weekdays" do
    refute SwitchWindow.new(valid_attrs.merge(days: [])).valid?
    refute SwitchWindow.new(valid_attrs.merge(days: [ 0 ])).valid?
    refute SwitchWindow.new(valid_attrs.merge(days: [ 8 ])).valid?
  end

  test "days are normalized to sorted unique integers, blanks dropped" do
    w = SwitchWindow.create!(valid_attrs.merge(days: [ "", "5", "1", "5" ]))
    assert_equal [ 1, 5 ], w.days
  end

  test "crosses_midnight? when on_at > off_at" do
    assert SwitchWindow.new(valid_attrs.merge(on_at: 1320, off_at: 360)).crosses_midnight?
    refute SwitchWindow.new(valid_attrs).crosses_midnight?
  end

  test "on_at_time and off_at_time format and parse HH:MM" do
    w = SwitchWindow.new(valid_attrs)
    assert_equal "18:00", w.on_at_time
    assert_equal "23:00", w.off_at_time
    w.on_at_time = "07:05"
    assert_equal 425, w.on_at
    w.off_at_time = ""
    assert_nil w.off_at
  end

  test "enabled scope" do
    SwitchWindow.delete_all
    SwitchWindow.create!(valid_attrs)
    SwitchWindow.create!(valid_attrs.merge(enabled: false))
    assert_equal 1, SwitchWindow.enabled.count
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rtk bin/rails test test/models/switch_window_test.rb`
Expected: FAIL with `NameError: uninitialized constant SwitchWindow`

- [ ] **Step 3: Implement**

`app/models/switch_window.rb`:

```ruby
class SwitchWindow < ApplicationRecord
  ISO_DAYS = (1..7).to_a.freeze
  MINUTE_RANGE = (0..1439)

  before_validation :normalize_days

  validates :plug_id, presence: true
  validates :on_at,  inclusion: { in: MINUTE_RANGE, message: "muss zwischen 00:00 und 23:59 liegen" }
  validates :off_at, inclusion: { in: MINUTE_RANGE, message: "muss zwischen 00:00 und 23:59 liegen" }
  validate  :on_and_off_differ
  validate  :days_are_iso_weekdays

  scope :enabled, -> { where(enabled: true) }

  def crosses_midnight?
    on_at > off_at
  end

  def on_at_time  = format_minutes(on_at)
  def off_at_time = format_minutes(off_at)

  def on_at_time=(str)
    self.on_at = parse_minutes(str)
  end

  def off_at_time=(str)
    self.off_at = parse_minutes(str)
  end

  private

  def format_minutes(minutes)
    return nil if minutes.nil?
    format("%02d:%02d", minutes / 60, minutes % 60)
  end

  def parse_minutes(str)
    return nil unless str.to_s =~ /\A(\d{1,2}):(\d{2})\z/
    Integer($1) * 60 + Integer($2)
  end

  def normalize_days
    return unless days.is_a?(Array)
    self.days = days.reject { |d| d.to_s.strip.empty? }.map(&:to_i).uniq.sort
  end

  def on_and_off_differ
    return if on_at.nil? || off_at.nil?
    errors.add(:off_at, "muss sich von der Startzeit unterscheiden") if on_at == off_at
  end

  def days_are_iso_weekdays
    unless days.is_a?(Array) && days.any? && days.all? { |d| ISO_DAYS.include?(d) }
      errors.add(:days, "mindestens ein Wochentag muss gewählt sein")
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rtk bin/rails test test/models/switch_window_test.rb`
Expected: PASS (10 tests)

- [ ] **Step 5: Commit**

```bash
rtk git add app/models/switch_window.rb test/models/switch_window_test.rb
rtk git commit -m "Add SwitchWindow model"
```

---

### Task 4: SwitchCommand, PlugState, SchedulerState models

**Files:**
- Create: `app/models/switch_command.rb`
- Create: `app/models/plug_state.rb`
- Create: `app/models/scheduler_state.rb`
- Test: `test/models/switch_command_test.rb`, `test/models/plug_state_test.rb`, `test/models/scheduler_state_test.rb`

- [ ] **Step 1: Write the failing tests**

`test/models/switch_command_test.rb`:

```ruby
require "test_helper"

class SwitchCommandTest < ActiveSupport::TestCase
  setup { SwitchCommand.delete_all }

  test "validates action and source" do
    refute SwitchCommand.new(plug_id: "x", action: "toggle", source: "manual").valid?
    refute SwitchCommand.new(plug_id: "x", action: "on", source: "api").valid?
    assert SwitchCommand.new(plug_id: "x", action: "on", source: "schedule").valid?
  end

  test "latest_for returns newest command for plug" do
    SwitchCommand.create!(plug_id: "a", action: "on",  source: "manual",   created_at: 2.hours.ago)
    SwitchCommand.create!(plug_id: "a", action: "off", source: "schedule", created_at: 1.hour.ago)
    SwitchCommand.create!(plug_id: "b", action: "on",  source: "manual",   created_at: 1.minute.ago)
    assert_equal "off", SwitchCommand.latest_for("a").action
    assert_nil SwitchCommand.latest_for("missing")
  end

  test "manual_after? only counts manual commands after the given time" do
    SwitchCommand.create!(plug_id: "a", action: "on", source: "schedule", created_at: 1.minute.ago)
    refute SwitchCommand.manual_after?("a", 5.minutes.ago)
    SwitchCommand.create!(plug_id: "a", action: "off", source: "manual", created_at: 1.minute.ago)
    assert SwitchCommand.manual_after?("a", 5.minutes.ago)
    refute SwitchCommand.manual_after?("a", Time.current)
  end
end
```

`test/models/plug_state_test.rb`:

```ruby
require "test_helper"

class PlugStateTest < ActiveSupport::TestCase
  setup { PlugState.delete_all }

  test "record_output creates a row and returns true" do
    assert PlugState.record_output("fridge", true)
    assert_equal true, PlugState.find_by(plug_id: "fridge").output
  end

  test "record_output with unchanged output writes nothing and returns false" do
    travel_to Time.zone.local(2026, 6, 15, 12, 0) do
      PlugState.record_output("fridge", true)
    end
    travel_to Time.zone.local(2026, 6, 15, 12, 5) do
      refute PlugState.record_output("fridge", true)
    end
    assert_equal Time.zone.local(2026, 6, 15, 12, 0), PlugState.find_by(plug_id: "fridge").updated_at
  end

  test "record_output updates on change" do
    PlugState.record_output("fridge", true)
    assert PlugState.record_output("fridge", false)
    assert_equal false, PlugState.find_by(plug_id: "fridge").output
    assert_equal 1, PlugState.count
  end
end
```

`test/models/scheduler_state_test.rb`:

```ruby
require "test_helper"

class SchedulerStateTest < ActiveSupport::TestCase
  setup { SchedulerState.delete_all }

  test "last_tick_at is nil without a row" do
    assert_nil SchedulerState.last_tick_at
  end

  test "advance! creates then updates a single row" do
    t1 = Time.zone.local(2026, 6, 15, 12, 0)
    t2 = Time.zone.local(2026, 6, 15, 12, 1)
    SchedulerState.advance!(t1)
    assert_equal t1, SchedulerState.last_tick_at
    SchedulerState.advance!(t2)
    assert_equal t2, SchedulerState.last_tick_at
    assert_equal 1, SchedulerState.count
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rtk bin/rails test test/models/switch_command_test.rb test/models/plug_state_test.rb test/models/scheduler_state_test.rb`
Expected: FAIL with `NameError` for each missing constant.

- [ ] **Step 3: Implement the three models**

`app/models/switch_command.rb`:

```ruby
class SwitchCommand < ApplicationRecord
  ACTIONS = %w[on off].freeze
  SOURCES = %w[manual schedule].freeze

  validates :plug_id, presence: true
  validates :action, inclusion: { in: ACTIONS }
  validates :source, inclusion: { in: SOURCES }

  def self.latest_for(plug_id)
    where(plug_id: plug_id).order(created_at: :desc, id: :desc).first
  end

  def self.manual_after?(plug_id, time)
    where(plug_id: plug_id, source: "manual").where("created_at > ?", time).exists?
  end
end
```

`app/models/plug_state.rb`:

```ruby
class PlugState < ApplicationRecord
  validates :plug_id, presence: true, uniqueness: true
  validates :output, inclusion: { in: [ true, false ] }

  # Returns true when the stored output actually changed (and was written).
  def self.record_output(plug_id, output)
    state = find_or_initialize_by(plug_id: plug_id)
    return false if state.persisted? && state.output == output
    state.update!(output: output)
    true
  end
end
```

`app/models/scheduler_state.rb`:

```ruby
class SchedulerState < ApplicationRecord
  # Single-row table: the schedule tick watermark.
  def self.last_tick_at
    first&.last_tick_at
  end

  def self.advance!(time)
    (first || new).update!(last_tick_at: time)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rtk bin/rails test test/models/switch_command_test.rb test/models/plug_state_test.rb test/models/scheduler_state_test.rb`
Expected: PASS (8 tests)

- [ ] **Step 5: Commit**

```bash
rtk git add app/models/switch_command.rb app/models/plug_state.rb app/models/scheduler_state.rb test/models/switch_command_test.rb test/models/plug_state_test.rb test/models/scheduler_state_test.rb
rtk git commit -m "Add SwitchCommand, PlugState and SchedulerState models"
```

---

### Task 5: SwitchEdgeCalculator (pure edge PORO)

**Files:**
- Create: `app/models/switch_edge_calculator.rb`
- Test: `test/models/switch_edge_calculator_test.rb`

Semantics: a window contributes an **on edge** at `on_at` on every date whose ISO weekday (`Date#cwday`) is in `days`, and an **off edge** at `off_at` on the same date — or the following date when `on_at > off_at` (midnight crossing). `edges_between(from, to)` returns edges with `from < at <= to`, sorted ascending. All times in the given timezone (default `Time.zone`, which is Europe/Berlin in this app). Reference dates used in tests: 2026-06-15 is a Monday; DST spring-forward in Europe/Berlin is Sunday 2026-03-29 (02:00→03:00).

- [ ] **Step 1: Write the failing tests**

`test/models/switch_edge_calculator_test.rb`:

```ruby
require "test_helper"

class SwitchEdgeCalculatorTest < ActiveSupport::TestCase
  # Pure unit tests: windows are plain structs, no DB.
  W = Struct.new(:plug_id, :on_at, :off_at, :days, keyword_init: true)

  def tz = Time.zone

  def calc(*windows)
    SwitchEdgeCalculator.new(windows: windows)
  end

  test "fires on and off edges on configured weekdays" do
    c = calc(W.new(plug_id: "lamp", on_at: 1080, off_at: 1380, days: [ 1 ]))  # Mo 18:00-23:00
    edges = c.edges_between(tz.local(2026, 6, 15, 0, 0), tz.local(2026, 6, 16, 0, 0))
    assert_equal 2, edges.length
    assert_equal [ :on, :off ], edges.map(&:action)
    assert_equal tz.local(2026, 6, 15, 18, 0), edges.first.at
    assert_equal tz.local(2026, 6, 15, 23, 0), edges.last.at
    assert_equal "lamp", edges.first.plug_id
  end

  test "skips days not in the weekday list" do
    c = calc(W.new(plug_id: "lamp", on_at: 1080, off_at: 1380, days: [ 2 ]))  # Di only
    edges = c.edges_between(tz.local(2026, 6, 15, 0, 0), tz.local(2026, 6, 16, 0, 0))
    assert_empty edges
  end

  test "midnight-crossing window puts the off edge on the next day" do
    c = calc(W.new(plug_id: "lamp", on_at: 1320, off_at: 360, days: [ 1 ]))  # Mo 22:00-06:00
    edges = c.edges_between(tz.local(2026, 6, 15, 0, 0), tz.local(2026, 6, 17, 0, 0))
    assert_equal tz.local(2026, 6, 15, 22, 0), edges.first.at
    assert_equal tz.local(2026, 6, 16, 6, 0),  edges.last.at
  end

  test "off edge of a window started the previous day is found" do
    c = calc(W.new(plug_id: "lamp", on_at: 1320, off_at: 360, days: [ 1 ]))
    # Interval starts Tuesday 05:00 — only the off edge (Tue 06:00) is inside.
    edges = c.edges_between(tz.local(2026, 6, 16, 5, 0), tz.local(2026, 6, 16, 7, 0))
    assert_equal 1, edges.length
    assert_equal :off, edges.first.action
    assert_equal tz.local(2026, 6, 16, 6, 0), edges.first.at
  end

  test "interval is exclusive at from, inclusive at to" do
    c = calc(W.new(plug_id: "lamp", on_at: 1080, off_at: 1380, days: [ 1 ]))
    on_time = tz.local(2026, 6, 15, 18, 0)
    assert_empty c.edges_between(on_time, tz.local(2026, 6, 15, 18, 30))
    edges = c.edges_between(tz.local(2026, 6, 15, 17, 0), on_time)
    assert_equal [ on_time ], edges.map(&:at)
  end

  test "empty or inverted interval returns no edges" do
    c = calc(W.new(plug_id: "lamp", on_at: 1080, off_at: 1380, days: [ 1 ]))
    t = tz.local(2026, 6, 15, 12, 0)
    assert_empty c.edges_between(t, t)
    assert_empty c.edges_between(t, t - 1.hour)
  end

  test "latest_edge_per_plug collapses to the most recent edge per plug" do
    c = calc(
      W.new(plug_id: "lamp", on_at: 1080, off_at: 1140, days: [ 1 ]),  # Mo 18:00-19:00
      W.new(plug_id: "fan",  on_at: 1100, off_at: 1380, days: [ 1 ])   # Mo 18:20-23:00
    )
    edges = c.latest_edge_per_plug(tz.local(2026, 6, 15, 17, 0), tz.local(2026, 6, 15, 20, 0))
    assert_equal 2, edges.length
    lamp = edges.find { |e| e.plug_id == "lamp" }
    fan  = edges.find { |e| e.plug_id == "fan" }
    assert_equal :off, lamp.action  # 19:00 beats 18:00
    assert_equal :on,  fan.action   # only 18:20 inside (off is 23:00, outside)
  end

  test "spring-forward gap shifts the edge forward" do
    # 2026-03-29 (Sunday) 02:00 -> 03:00 in Europe/Berlin; 02:30 does not exist.
    c = calc(W.new(plug_id: "lamp", on_at: 150, off_at: 240, days: [ 7 ]))  # So 02:30-04:00
    edges = c.edges_between(tz.local(2026, 3, 29, 0, 0), tz.local(2026, 3, 29, 12, 0))
    assert_equal 2, edges.length
    assert_equal 3, edges.first.at.hour
    assert_equal 30, edges.first.at.min
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rtk bin/rails test test/models/switch_edge_calculator_test.rb`
Expected: FAIL with `NameError: uninitialized constant SwitchEdgeCalculator`

- [ ] **Step 3: Implement**

`app/models/switch_edge_calculator.rb`:

```ruby
# Pure edge computation: no I/O, no clock. Windows only need to respond to
# plug_id, on_at, off_at and days (SwitchWindow records or plain structs).
class SwitchEdgeCalculator
  Edge = Struct.new(:plug_id, :action, :at, keyword_init: true)

  def initialize(windows:, timezone: Time.zone)
    @windows = windows
    @tz      = timezone
  end

  # All edges with from < at <= to, ascending by time.
  def edges_between(from, to)
    return [] if to <= from

    first_date = from.in_time_zone(@tz).to_date - 1  # catches off edges of midnight-crossers
    last_date  = to.in_time_zone(@tz).to_date
    (first_date..last_date)
      .flat_map { |date| edges_for_date(date) }
      .select { |e| e.at > from && e.at <= to }
      .sort_by(&:at)
  end

  # At most one edge per plug: the latest within the interval.
  def latest_edge_per_plug(from, to)
    edges_between(from, to).group_by(&:plug_id).map { |_, edges| edges.last }
  end

  private

  def edges_for_date(date)
    @windows.select { |w| w.days.include?(date.cwday) }.flat_map do |w|
      off_date = w.on_at > w.off_at ? date + 1 : date
      [
        Edge.new(plug_id: w.plug_id, action: :on,  at: local_time(date, w.on_at)),
        Edge.new(plug_id: w.plug_id, action: :off, at: local_time(off_date, w.off_at))
      ]
    end
  end

  def local_time(date, minutes)
    @tz.local(date.year, date.month, date.day, minutes / 60, minutes % 60)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rtk bin/rails test test/models/switch_edge_calculator_test.rb`
Expected: PASS (8 tests)

- [ ] **Step 5: Commit**

```bash
rtk git add app/models/switch_edge_calculator.rb test/models/switch_edge_calculator_test.rb
rtk git commit -m "Add SwitchEdgeCalculator for window edge computation"
```

---

### Task 6: PlugCommander

**Files:**
- Create: `app/models/plug_commander.rb`
- Test: `test/models/plug_commander_test.rb`

- [ ] **Step 1: Write the failing tests**

`test/models/plug_commander_test.rb`:

```ruby
require "test_helper"
require "config_loader"

class PlugCommanderTest < ActiveSupport::TestCase
  class FakeMqtt
    attr_reader :published, :disconnected

    def initialize(fail_connect: false)
      @fail_connect = fail_connect
      @published    = []
      @disconnected = false
    end

    def connect
      raise Errno::ECONNREFUSED, "broker down" if @fail_connect
    end

    def publish(topic, payload) = @published << [ topic, payload ]
    def disconnect = @disconnected = true
  end

  setup do
    SwitchCommand.delete_all
    @mqtt_config = ConfigLoader::MqttCfg.new(host: "localhost", port: 1883, topic_prefix: "shellies")
    @plug = ConfigLoader::PlugCfg.new(id: "lamp", name: "Lampe", role: :consumer,
                                      driver: :shelly, ain: nil, switchable: true)
  end

  def commander(client)
    PlugCommander.new(mqtt_config: @mqtt_config, mqtt_factory: -> { client })
  end

  test "publishes on to the shelly command topic and logs the command" do
    client = FakeMqtt.new
    commander(client).switch(@plug, :on, source: :manual)
    assert_equal [ [ "shellies/lamp/command/switch:0", "on" ] ], client.published
    assert client.disconnected
    cmd = SwitchCommand.last
    assert_equal %w[lamp on manual], [ cmd.plug_id, cmd.action, cmd.source ]
  end

  test "publishes off with source schedule" do
    client = FakeMqtt.new
    commander(client).switch(@plug, :off, source: :schedule)
    assert_equal [ [ "shellies/lamp/command/switch:0", "off" ] ], client.published
    assert_equal %w[off schedule], [ SwitchCommand.last.action, SwitchCommand.last.source ]
  end

  test "failed publish raises and writes no log row" do
    client = FakeMqtt.new(fail_connect: true)
    assert_raises(PlugCommander::Error) { commander(client).switch(@plug, :on, source: :manual) }
    assert_equal 0, SwitchCommand.count
  end

  test "unknown driver raises a clear error" do
    fritz = ConfigLoader::PlugCfg.new(id: "tv", name: "TV", role: :consumer,
                                      driver: :fritz_dect, ain: "1", switchable: true)
    e = assert_raises(PlugCommander::Error) { commander(FakeMqtt.new).switch(fritz, :on, source: :manual) }
    assert_match(/fritz_dect/, e.message)
    assert_equal 0, SwitchCommand.count
  end

  test "non-switchable plug raises" do
    plain = ConfigLoader::PlugCfg.new(id: "bkw", name: "BKW", role: :producer,
                                      driver: :shelly, ain: nil, switchable: false)
    assert_raises(PlugCommander::Error) { commander(FakeMqtt.new).switch(plain, :on, source: :manual) }
  end

  test "invalid action raises ArgumentError" do
    assert_raises(ArgumentError) { commander(FakeMqtt.new).switch(@plug, :toggle, source: :manual) }
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rtk bin/rails test test/models/plug_commander_test.rb`
Expected: FAIL with `NameError: uninitialized constant PlugCommander`

- [ ] **Step 3: Implement**

`app/models/plug_commander.rb`:

```ruby
require "mqtt"

# The single choke point for switching plugs. Publishes over a short-lived
# MQTT connection and logs to switch_commands only after a successful publish.
class PlugCommander
  class Error < StandardError; end

  ACTIONS = %i[on off].freeze

  def self.switch(plug, action, source:, mqtt_config:)
    new(mqtt_config: mqtt_config).switch(plug, action, source: source)
  end

  def initialize(mqtt_config:, mqtt_factory: nil)
    @mqtt_config  = mqtt_config
    @mqtt_factory = mqtt_factory || -> {
      MQTT::Client.new(host: @mqtt_config.host, port: @mqtt_config.port)
    }
  end

  def switch(plug, action, source:)
    raise ArgumentError, "action must be one of #{ACTIONS}" unless ACTIONS.include?(action)
    raise Error, "plug '#{plug.id}' is not switchable" unless plug.switchable

    publish(plug, action)
    SwitchCommand.create!(plug_id: plug.id, action: action.to_s, source: source.to_s)
  end

  private

  def publish(plug, action)
    case plug.driver
    when :shelly then publish_shelly(plug, action)
    else raise Error, "no switch driver for '#{plug.driver}' (plug '#{plug.id}')"
    end
  end

  def publish_shelly(plug, action)
    client = @mqtt_factory.call
    begin
      client.connect
      client.publish("#{@mqtt_config.topic_prefix}/#{plug.id}/command/switch:0", action.to_s)
    rescue StandardError => e
      raise Error, "MQTT publish for '#{plug.id}' failed: #{e.class}: #{e.message}"
    ensure
      begin; client.disconnect; rescue StandardError; nil; end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rtk bin/rails test test/models/plug_commander_test.rb`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
rtk git add app/models/plug_commander.rb test/models/plug_commander_test.rb
rtk git commit -m "Add PlugCommander as single switch choke point"
```

---

### Task 7: ScheduleTickJob + recurring schedule

**Files:**
- Create: `app/jobs/schedule_tick_job.rb`
- Modify: `config/recurring.yml`
- Test: `test/jobs/schedule_tick_job_test.rb`

The job stubs `PlugCommander.switch` in tests via `Minitest::Mock`-style `.stub` (kwargs pass through; the bundled minitest supports this). The test config (`config/ziwoas.test.yml`) has `fridge` as the only switchable plug.

- [ ] **Step 1: Write the failing tests**

`test/jobs/schedule_tick_job_test.rb`:

```ruby
require "test_helper"

class ScheduleTickJobTest < ActiveSupport::TestCase
  setup do
    SchedulerState.delete_all
    SwitchWindow.delete_all
    SwitchCommand.delete_all
    @calls = []
    @recorder = ->(plug, action, source:, mqtt_config:) { @calls << [ plug.id, action, source ] }
  end

  def monday_18_05 = Time.zone.local(2026, 6, 15, 18, 5)

  def create_window(on_at: 1080, off_at: 1380, days: [ 1 ], plug_id: "fridge", enabled: true)
    SwitchWindow.create!(plug_id: plug_id, on_at: on_at, off_at: off_at, days: days, enabled: enabled)
  end

  test "first run only initializes the watermark" do
    create_window
    travel_to monday_18_05 do
      PlugCommander.stub :switch, @recorder do
        ScheduleTickJob.perform_now
      end
      assert_equal Time.current, SchedulerState.last_tick_at
    end
    assert_empty @calls
  end

  test "fires the edge between watermark and now and advances the watermark" do
    create_window  # Mo 18:00-23:00, on edge at 18:00
    travel_to monday_18_05 do
      SchedulerState.advance!(10.minutes.ago)
      PlugCommander.stub :switch, @recorder do
        ScheduleTickJob.perform_now
      end
      assert_equal [ [ "fridge", :on, :schedule ] ], @calls
      assert_equal Time.current, SchedulerState.last_tick_at
    end
  end

  test "collapses multiple missed edges to the latest per plug" do
    create_window(on_at: 1080, off_at: 1083)  # Mo 18:00-18:03 -> on@18:00, off@18:03
    travel_to monday_18_05 do
      SchedulerState.advance!(10.minutes.ago)
      PlugCommander.stub :switch, @recorder do
        ScheduleTickJob.perform_now
      end
      assert_equal [ [ "fridge", :off, :schedule ] ], @calls
    end
  end

  test "skips the edge when a manual command came after the edge time" do
    create_window  # on edge 18:00
    travel_to monday_18_05 do
      SwitchCommand.create!(plug_id: "fridge", action: "off", source: "manual",
                            created_at: Time.zone.local(2026, 6, 15, 18, 1))
      SchedulerState.advance!(10.minutes.ago)
      PlugCommander.stub :switch, @recorder do
        ScheduleTickJob.perform_now
      end
      assert_empty @calls
      assert_equal Time.current, SchedulerState.last_tick_at
    end
  end

  test "ignores disabled windows and windows of unknown plugs" do
    create_window(enabled: false)
    create_window(plug_id: "gone")
    travel_to monday_18_05 do
      SchedulerState.advance!(10.minutes.ago)
      PlugCommander.stub :switch, @recorder do
        ScheduleTickJob.perform_now
      end
    end
    assert_empty @calls
  end

  test "watermark stays put when a publish fails" do
    create_window
    failing = ->(*, **) { raise PlugCommander::Error, "broker down" }
    travel_to monday_18_05 do
      watermark = 10.minutes.ago
      SchedulerState.advance!(watermark)
      PlugCommander.stub :switch, failing do
        ScheduleTickJob.perform_now
      end
      assert_equal watermark, SchedulerState.last_tick_at
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rtk bin/rails test test/jobs/schedule_tick_job_test.rb`
Expected: FAIL with `NameError: uninitialized constant ScheduleTickJob`

- [ ] **Step 3: Implement the job**

`app/jobs/schedule_tick_job.rb`:

```ruby
require "config_loader"

class ScheduleTickJob < ApplicationJob
  queue_as :default

  def perform
    config    = load_config
    now       = Time.current
    watermark = SchedulerState.last_tick_at

    # First run ever: set the watermark and stop — no unbounded replay.
    return SchedulerState.advance!(now) if watermark.nil?

    plugs   = config.plugs.select(&:switchable).index_by(&:id)
    windows = SwitchWindow.enabled.where(plug_id: plugs.keys)
    edges   = SwitchEdgeCalculator.new(windows: windows)
                                  .latest_edge_per_plug(watermark, now)
    edges   = edges.reject { |edge| SwitchCommand.manual_after?(edge.plug_id, edge.at) }

    failed = false
    edges.each do |edge|
      PlugCommander.switch(plugs.fetch(edge.plug_id), edge.action,
                           source: :schedule, mqtt_config: config.mqtt)
    rescue PlugCommander::Error => e
      failed = true
      Rails.logger.warn("ScheduleTick: #{edge.plug_id} #{edge.action} failed: #{e.message}")
    end

    # Keep the watermark so the next tick retries; repeated on/off is idempotent.
    SchedulerState.advance!(now) unless failed
  end

  private

  def load_config
    path = Rails.root.join("config", Rails.env.test? ? "ziwoas.test.yml" : "ziwoas.yml").to_s
    ConfigLoader.load(path)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rtk bin/rails test test/jobs/schedule_tick_job_test.rb`
Expected: PASS (6 tests)

- [ ] **Step 5: Add the recurring schedule**

In `config/recurring.yml`, append under the `aggregator_schedule` anchor block (after `poll_sensors`, same indentation):

```yaml
  schedule_tick:
    class: ScheduleTickJob
    queue: default
    schedule: every minute
```

- [ ] **Step 6: Commit**

```bash
rtk git add app/jobs/schedule_tick_job.rb config/recurring.yml test/jobs/schedule_tick_job_test.rb
rtk git commit -m "Add minutely ScheduleTickJob with watermark catch-up"
```

---

### Task 8: MqttSubscriber reads `output`

**Files:**
- Modify: `lib/mqtt_subscriber.rb`
- Test: `test/test_mqtt_subscriber.rb`

Shelly Gen2 `status/switch:0` payloads contain `"output": true|false`. The FRITZ bridge payloads (`lib/fritz_mqtt_bridge.rb`) don't — `output` stays absent and must be ignored.

- [ ] **Step 1: Write the failing tests**

In `test/test_mqtt_subscriber.rb`, extend the payload helper and add tests. Replace the existing `status_payload` method with:

```ruby
def status_payload(apower:, total:, output: nil)
  h = { "apower" => apower, "aenergy" => { "total" => total } }
  h["output"] = output unless output.nil?
  JSON.generate(h)
end
```

Add to `setup` (after `Sample.delete_all`): `PlugState.delete_all`.

Append these tests:

```ruby
test "handle_message records output state" do
  @subscriber.handle_message("shellies/fridge/status/switch:0",
                             status_payload(apower: 50.0, total: 1.0, output: true))
  assert_equal true, PlugState.find_by(plug_id: "fridge").output
end

test "handle_message updates output state on change" do
  @subscriber.handle_message("shellies/fridge/status/switch:0",
                             status_payload(apower: 50.0, total: 1.0, output: true))
  @now += 1
  @subscriber.handle_message("shellies/fridge/status/switch:0",
                             status_payload(apower: 0.0, total: 1.0, output: false))
  assert_equal false, PlugState.find_by(plug_id: "fridge").output
  assert_equal 1, PlugState.count
end

test "handle_message without output field leaves plug_states untouched" do
  @subscriber.handle_message("shellies/fridge/status/switch:0",
                             status_payload(apower: 50.0, total: 1.0))
  assert_equal 0, PlugState.count
end

test "handle_message includes output in the broadcast payload" do
  capture_broadcasts do |broadcasts|
    @subscriber.handle_message("shellies/fridge/status/switch:0",
                               status_payload(apower: 50.0, total: 1.0, output: true))
    _, payload = broadcasts.first
    assert_equal true, payload[:plugs].first[:output]
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rtk bin/rails test test/test_mqtt_subscriber.rb`
Expected: the 4 new tests FAIL (no PlugState rows, no `:output` key); the existing 8 still pass.

- [ ] **Step 3: Implement**

In `lib/mqtt_subscriber.rb`, change `handle_message`: after the `aenergy_wh` line, parse and record output, and pass it to `accumulate`:

```ruby
    data       = JSON.parse(payload)
    apower_w   = data["apower"].to_f
    aenergy_wh = data.dig("aenergy", "total").to_f
    output     = data["output"]
    ts         = @clock.call.to_i

    Sample.create!(plug_id: plug_id, ts: ts, apower_w: apower_w, aenergy_wh: aenergy_wh)
    PlugState.record_output(plug_id, output) unless output.nil?
    @logger.debug("MqttSubscriber: #{plug_id} #{apower_w} W / #{aenergy_wh} Wh")
    accumulate(plug, ts, apower_w, aenergy_wh, output)
```

Change the `accumulate` signature and pending hash:

```ruby
  def accumulate(plug, ts, apower_w, aenergy_wh, output = nil)
```

and in the `@pending[plug.id] = { ... }` hash add after `aenergy_wh:`:

```ruby
      aenergy_wh:  aenergy_wh,
      output:      output
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rtk bin/rails test test/test_mqtt_subscriber.rb`
Expected: PASS (12 tests)

- [ ] **Step 5: Commit**

```bash
rtk git add lib/mqtt_subscriber.rb test/test_mqtt_subscriber.rb
rtk git commit -m "Track plug output state from Shelly status messages"
```

---

### Task 9: SwitchRow view model + SwitchesHelper

**Files:**
- Create: `app/models/switch_row.rb`
- Create: `app/helpers/switches_helper.rb`
- Test: `test/models/switch_row_test.rb`, `test/helpers/switches_helper_test.rb`

- [ ] **Step 1: Write the failing SwitchRow tests**

`test/models/switch_row_test.rb`:

```ruby
require "test_helper"
require "config_loader"

class SwitchRowTest < ActiveSupport::TestCase
  setup do
    Sample.delete_all
    PlugState.delete_all
    SwitchCommand.delete_all
    SwitchWindow.delete_all
    @plug = ConfigLoader::PlugCfg.new(id: "fridge", name: "Kühlschrank", role: :consumer,
                                      driver: :shelly, ain: nil, switchable: true)
  end

  test "build collects state, last command, windows, watt and next edge" do
    travel_to Time.zone.local(2026, 6, 15, 17, 0) do  # Monday
      PlugState.record_output("fridge", true)
      SwitchCommand.create!(plug_id: "fridge", action: "on", source: "schedule")
      SwitchWindow.create!(plug_id: "fridge", on_at: 1080, off_at: 1380, days: [ 1 ])
      Sample.create!(plug_id: "fridge", ts: Time.current.to_i - 30, apower_w: 42.0, aenergy_wh: 1.0)

      row = SwitchRow.build(@plug)
      assert row.on?
      refute row.offline?
      assert_in_delta 42.0, row.watt
      assert_equal 1, row.windows.size
      assert_equal :on, row.next_edge.action
      assert_equal Time.zone.local(2026, 6, 15, 18, 0), row.next_edge.at
      assert_equal "on", row.last_command.action
    end
  end

  test "offline when last sample is older than 5 minutes or missing" do
    travel_to Time.zone.local(2026, 6, 15, 17, 0) do
      assert SwitchRow.build(@plug).offline?
      Sample.create!(plug_id: "fridge", ts: 6.minutes.ago.to_i, apower_w: 1.0, aenergy_wh: 1.0)
      assert SwitchRow.build(@plug).offline?
      Sample.create!(plug_id: "fridge", ts: 4.minutes.ago.to_i, apower_w: 1.0, aenergy_wh: 1.0)
      refute SwitchRow.build(@plug).offline?
    end
  end

  test "on? falls back to last command without plug state, default off" do
    refute SwitchRow.build(@plug).on?
    SwitchCommand.create!(plug_id: "fridge", action: "on", source: "manual")
    assert SwitchRow.build(@plug).on?
  end

  test "disabled windows do not produce a next edge" do
    travel_to Time.zone.local(2026, 6, 15, 17, 0) do
      SwitchWindow.create!(plug_id: "fridge", on_at: 1080, off_at: 1380, days: [ 1 ], enabled: false)
      row = SwitchRow.build(@plug)
      assert_nil row.next_edge
      refute row.schedule?
      assert_equal 1, row.windows.size  # still listed for editing
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `rtk bin/rails test test/models/switch_row_test.rb`
Expected: FAIL with `NameError: uninitialized constant SwitchRow`

- [ ] **Step 3: Implement SwitchRow**

`app/models/switch_row.rb`:

```ruby
# Per-plug view model for the "Schalten" tab.
class SwitchRow
  OFFLINE_AFTER = 5.minutes
  LOOKAHEAD     = 7.days

  attr_reader :plug, :windows, :state, :last_command, :next_edge, :last_seen_at, :watt, :now

  def self.build_all(plugs, now: Time.current)
    plugs.map { |plug| build(plug, now: now) }
  end

  def self.build(plug, now: Time.current)
    windows     = SwitchWindow.where(plug_id: plug.id).order(:on_at, :id).to_a
    last_sample = Sample.where(plug_id: plug.id).order(ts: :desc).first
    next_edge   = SwitchEdgeCalculator.new(windows: windows.select(&:enabled))
                                      .edges_between(now, now + LOOKAHEAD).first
    new(
      plug:         plug,
      windows:      windows,
      state:        PlugState.find_by(plug_id: plug.id),
      last_command: SwitchCommand.latest_for(plug.id),
      next_edge:    next_edge,
      last_seen_at: last_sample && Time.zone.at(last_sample.ts),
      watt:         last_sample&.apower_w,
      now:          now,
    )
  end

  def initialize(plug:, windows:, state:, last_command:, next_edge:, last_seen_at:, watt:, now: Time.current)
    @plug         = plug
    @windows      = windows
    @state        = state
    @last_command = last_command
    @next_edge    = next_edge
    @last_seen_at = last_seen_at
    @watt         = watt
    @now          = now
  end

  def on?
    return state.output if state
    return last_command.action == "on" if last_command
    false
  end

  def offline?
    last_seen_at.nil? || last_seen_at < now - OFFLINE_AFTER
  end

  def schedule?
    windows.any?(&:enabled)
  end
end
```

- [ ] **Step 4: Run SwitchRow tests**

Run: `rtk bin/rails test test/models/switch_row_test.rb`
Expected: PASS (4 tests)

- [ ] **Step 5: Write the failing helper tests**

`test/helpers/switches_helper_test.rb`:

```ruby
require "test_helper"

class SwitchesHelperTest < ActionView::TestCase
  include SwitchesHelper

  def row(on: true, offline: false, last_command: nil, next_edge: nil, windows: [], last_seen_at: nil)
    now = Time.zone.local(2026, 6, 15, 19, 0)
    seen = offline ? last_seen_at : now - 1.minute
    SwitchRow.new(
      plug: nil, windows: windows,
      state: PlugState.new(plug_id: "x", output: on),
      last_command: last_command, next_edge: next_edge,
      last_seen_at: seen, watt: nil, now: now
    )
  end

  def edge(action, hour, min)
    SwitchEdgeCalculator::Edge.new(plug_id: "x", action: action,
                                   at: Time.zone.local(2026, 6, 15, hour, min))
  end

  test "weekday_label formats ranges, singles and full week" do
    assert_equal "Mo–Fr", weekday_label([ 1, 2, 3, 4, 5 ])
    assert_equal "Sa–So", weekday_label([ 6, 7 ])
    assert_equal "Mo, Mi, Fr", weekday_label([ 1, 3, 5 ])
    assert_equal "Mo–Mi, Fr", weekday_label([ 1, 2, 3, 5 ])
    assert_equal "täglich", weekday_label([ 1, 2, 3, 4, 5, 6, 7 ])
    assert_equal "Do", weekday_label([ 4 ])
  end

  test "window_label combines weekdays and times" do
    w = SwitchWindow.new(plug_id: "x", on_at: 1080, off_at: 1380, days: [ 1, 2, 3, 4, 5 ])
    assert_equal "Mo–Fr · 18:00–23:00", window_label(w)
  end

  test "status line shows state with source and time when command matches" do
    cmd = SwitchCommand.new(plug_id: "x", action: "on", source: "schedule",
                            created_at: Time.zone.local(2026, 6, 15, 18, 0))
    line = switch_status_line(row(on: true, last_command: cmd, next_edge: edge(:off, 23, 0),
                                  windows: [ SwitchWindow.new(enabled: true) ]))
    assert_equal "an seit 18:00 (Zeitplan) · nächste Schaltung: 23:00 → aus", line
  end

  test "status line shows bare state when command mismatches, and kein Zeitplan" do
    cmd = SwitchCommand.new(plug_id: "x", action: "on", source: "manual",
                            created_at: Time.zone.local(2026, 6, 15, 18, 0))
    assert_equal "aus · kein Zeitplan", switch_status_line(row(on: false, last_command: cmd))
  end

  test "status line for offline plug shows minutes since last message" do
    line = switch_status_line(row(offline: true, last_seen_at: Time.zone.local(2026, 6, 15, 18, 35)))
    assert_equal "keine Statusmeldung seit 25 min", line
    assert_equal "noch keine Statusmeldung", switch_status_line(row(offline: true))
  end
end
```

- [ ] **Step 6: Run to verify failure**

Run: `rtk bin/rails test test/helpers/switches_helper_test.rb`
Expected: FAIL with `NameError: uninitialized constant SwitchesHelper`

- [ ] **Step 7: Implement the helper**

`app/helpers/switches_helper.rb`:

```ruby
module SwitchesHelper
  DAY_ABBR = { 1 => "Mo", 2 => "Di", 3 => "Mi", 4 => "Do", 5 => "Fr", 6 => "Sa", 7 => "So" }.freeze
  SOURCE_LABEL = { "manual" => "manuell", "schedule" => "Zeitplan" }.freeze

  def weekday_label(days)
    sorted = days.sort
    return "täglich" if sorted == SwitchWindow::ISO_DAYS
    sorted.slice_when { |a, b| b != a + 1 }
          .map { |group| group.size >= 2 ? "#{DAY_ABBR[group.first]}–#{DAY_ABBR[group.last]}" : DAY_ABBR[group.first] }
          .join(", ")
  end

  def window_label(window)
    "#{weekday_label(window.days)} · #{window.on_at_time}–#{window.off_at_time}"
  end

  def switch_status_line(row)
    return offline_line(row) if row.offline?

    state_word = row.on? ? "an" : "aus"
    cmd        = row.last_command
    first_part =
      if cmd && (cmd.action == "on") == row.on?
        "#{state_word} seit #{cmd.created_at.in_time_zone.strftime('%H:%M')} (#{SOURCE_LABEL[cmd.source]})"
      else
        state_word
      end
    [ first_part, schedule_part(row) ].join(" · ")
  end

  private

  def offline_line(row)
    return "noch keine Statusmeldung" if row.last_seen_at.nil?
    minutes = ((row.now - row.last_seen_at) / 60).round
    "keine Statusmeldung seit #{minutes} min"
  end

  def schedule_part(row)
    if row.next_edge
      arrow = row.next_edge.action == :on ? "an" : "aus"
      "nächste Schaltung: #{row.next_edge.at.strftime('%H:%M')} → #{arrow}"
    else
      "kein Zeitplan"
    end
  end
end
```

- [ ] **Step 8: Run helper tests**

Run: `rtk bin/rails test test/helpers/switches_helper_test.rb`
Expected: PASS (5 tests)

- [ ] **Step 9: Commit**

```bash
rtk git add app/models/switch_row.rb app/helpers/switches_helper.rb test/models/switch_row_test.rb test/helpers/switches_helper_test.rb
rtk git commit -m "Add SwitchRow view model and SwitchesHelper"
```

---

### Task 10: Routes, SwitchesController, views, nav, CSS

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/switches_controller.rb`
- Create: `app/views/switches/index.html.erb`, `_plug_card.html.erb`, `_head.html.erb`, `_windows.html.erb`, `_window.html.erb`, `_window_form.html.erb`
- Modify: `app/views/layouts/application.html.erb`
- Modify: `app/assets/stylesheets/application.css`
- Test: `test/controllers/switches_controller_test.rb`

- [ ] **Step 1: Write the failing controller tests**

`test/controllers/switches_controller_test.rb`:

```ruby
require "test_helper"

class SwitchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    SwitchWindow.delete_all
    PlugState.delete_all
    SwitchCommand.delete_all
    Sample.delete_all
  end

  test "GET /switches lists only switchable plugs" do
    get "/switches"
    assert_response :success
    assert_match "Kühlschrank", @response.body       # fridge: switchable in ziwoas.test.yml
    assert_no_match(/Balkonkraftwerk/, @response.body)  # bkw: producer, not switchable
  end

  test "shows the plug's windows" do
    SwitchWindow.create!(plug_id: "fridge", on_at: 1080, off_at: 1380, days: [ 1, 2, 3, 4, 5 ])
    get "/switches"
    assert_match "Mo–Fr · 18:00–23:00", @response.body
  end

  test "lists orphaned windows with delete option" do
    SwitchWindow.create!(plug_id: "gone", on_at: 60, off_at: 120, days: [ 1 ])
    get "/switches"
    assert_match "Verwaiste Zeitfenster", @response.body
    assert_match "gone", @response.body
  end

  test "no orphan section without orphans" do
    get "/switches"
    assert_no_match(/Verwaiste Zeitfenster/, @response.body)
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `rtk bin/rails test test/controllers/switches_controller_test.rb`
Expected: FAIL with routing error (`No route matches [GET] "/switches"`).

- [ ] **Step 3: Add routes**

In `config/routes.rb`, after the `get "/sensors/series"` line insert:

```ruby
  get "/switches", to: "switches#index", as: :switches

  scope "/plugs/:plug_id" do
    post "switch", to: "plug_switches#create", as: :plug_switch
    resources :switch_windows, only: %i[new create edit update destroy]
  end
```

(Route helpers: `switches_path`, `plug_switch_path(plug_id:)`, `new_switch_window_path(plug_id:)`, `switch_windows_path(plug_id:)`, `edit_switch_window_path(plug_id:, id:)`, `switch_window_path(plug_id:, id:)`.)

- [ ] **Step 4: Implement the controller**

`app/controllers/switches_controller.rb`:

```ruby
class SwitchesController < ApplicationController
  def index
    plugs    = app_config.plugs.select(&:switchable)
    @rows    = SwitchRow.build_all(plugs)
    @orphaned_windows = SwitchWindow.where.not(plug_id: plugs.map(&:id)).order(:plug_id, :on_at)
  end
end
```

- [ ] **Step 5: Create the views**

`app/views/switches/index.html.erb`:

```erb
<h1>Schalten</h1>

<div data-controller="switches">
  <% if @rows.empty? %>
    <p class="sw-empty">Keine schaltbaren Steckdosen konfiguriert. Markiere Verbraucher in <code>ziwoas.yml</code> mit <code>switchable: true</code>.</p>
  <% end %>

  <% @rows.each do |row| %>
    <%= render "switches/plug_card", row: row %>
  <% end %>

  <% if @orphaned_windows.any? %>
    <div class="section-label">Verwaiste Zeitfenster</div>
    <% @orphaned_windows.each do |window| %>
      <div class="sw-card sw-orphan" id="orphan_window_<%= window.id %>">
        <span class="sw-pill paused"><%= window.plug_id %> · <%= window_label(window) %></span>
        <%= button_to "🗑", switch_window_path(plug_id: window.plug_id, id: window.id),
                      method: :delete, class: "sw-icon-btn", form_class: "sw-inline-form" %>
      </div>
    <% end %>
  <% end %>
</div>
```

`app/views/switches/_plug_card.html.erb`:

```erb
<div class="sw-card<%= ' sw-offline' if row.offline? %>" id="sw_card_<%= row.plug.id %>" data-plug-id="<%= row.plug.id %>">
  <%= render "switches/head", row: row %>
  <details class="sw-details">
    <summary>Zeitfenster<%= " (#{row.windows.size})" if row.windows.any? %></summary>
    <%= render "switches/windows", plug: row.plug, windows: row.windows %>
  </details>
</div>
```

`app/views/switches/_head.html.erb`:

```erb
<div class="sw-row" id="sw_head_<%= row.plug.id %>">
  <%= button_to "", plug_switch_path(plug_id: row.plug.id, state: row.on? ? "off" : "on"),
                class: "sw-toggle#{' off' unless row.on?}",
                disabled: row.offline?,
                form_class: "sw-inline-form",
                aria: { label: "#{row.plug.name} #{row.on? ? 'ausschalten' : 'einschalten'}" } %>
  <div class="sw-info">
    <span class="sw-name"><%= row.plug.name %></span>
    <span class="sw-watt" data-switches-watt="<%= row.plug.id %>">· <%= row.offline? ? "offline" : "#{row.watt&.round || 0} W" %></span>
    <div class="sw-sub"><%= switch_status_line(row) %></div>
    <div class="sw-error" id="sw_error_<%= row.plug.id %>"></div>
  </div>
</div>
```

`app/views/switches/_windows.html.erb`:

```erb
<div id="sw_windows_<%= plug.id %>">
  <% windows.each do |window| %>
    <%= render "switches/window", plug: plug, window: window %>
  <% end %>
  <div id="sw_editor_<%= plug.id %>"></div>
  <%= link_to "+ Zeitfenster", new_switch_window_path(plug_id: plug.id),
              class: "sw-add", data: { turbo_stream: true } %>
</div>
```

`app/views/switches/_window.html.erb`:

```erb
<div class="sw-window" id="<%= dom_id(window) %>">
  <span class="sw-pill<%= ' paused' unless window.enabled %>"><%= window_label(window) %></span>
  <%= button_to window.enabled ? "⏸" : "▶",
                switch_window_path(plug_id: plug.id, id: window.id),
                method: :patch, params: { switch_window: { enabled: (!window.enabled).to_s } },
                class: "sw-icon-btn", form_class: "sw-inline-form" %>
  <%= link_to "✏️", edit_switch_window_path(plug_id: plug.id, id: window.id),
              class: "sw-icon-btn", data: { turbo_stream: true } %>
  <%= button_to "🗑", switch_window_path(plug_id: plug.id, id: window.id),
                method: :delete, class: "sw-icon-btn", form_class: "sw-inline-form" %>
</div>
```

`app/views/switches/_window_form.html.erb`:

```erb
<%= form_with model: window,
              url: window.persisted? ? switch_window_path(plug_id: plug.id, id: window.id)
                                     : switch_windows_path(plug_id: plug.id),
              class: "sw-form" do |f| %>
  <% if window.errors.any? %>
    <div class="sw-form-errors"><%= window.errors.full_messages.join(", ") %></div>
  <% end %>
  <div class="sw-form-row">
    <%= f.time_field :on_at_time, class: "sw-time" %>
    <span class="sw-hint">bis</span>
    <%= f.time_field :off_at_time, class: "sw-time" %>
  </div>
  <div class="sw-form-row">
    <input type="hidden" name="switch_window[days][]" value="">
    <% SwitchesHelper::DAY_ABBR.each do |num, label| %>
      <label class="sw-day">
        <%= check_box_tag "switch_window[days][]", num, window.days.include?(num),
                          id: "sw_day_#{plug.id}_#{window.id || 'new'}_#{num}" %>
        <span><%= label %></span>
      </label>
    <% end %>
  </div>
  <div class="sw-form-row sw-form-actions">
    <%= f.submit "Speichern", class: "sw-btn" %>
    <%= link_to "Abbrechen", switches_path, class: "sw-btn ghost" %>
    <span class="sw-hint">Über Mitternacht? Einfach 22:00–06:00 eintragen.</span>
  </div>
<% end %>
```

- [ ] **Step 6: Add the nav entry**

In `app/views/layouts/application.html.erb`, after the Dashboard link insert:

```erb
        <%= link_to "Schalten", switches_path, class: [ "app-nav-link", ("active" if current_page?(switches_path)) ] %>
```

- [ ] **Step 7: Add CSS**

Append to `app/assets/stylesheets/application.css`:

```css
/* ---- Schalten tab ---- */
.sw-card { background: var(--card); border: 1px solid var(--border); border-radius: 12px;
           padding: 12px 14px; margin-bottom: 10px; }
.sw-card.sw-offline { opacity: .6; }
.sw-row { display: flex; align-items: center; gap: 12px; }
.sw-info { flex: 1; min-width: 0; }
.sw-name { font-weight: 600; }
.sw-watt { color: var(--muted); font-variant-numeric: tabular-nums; }
.sw-sub { font-size: 12px; color: var(--muted); margin-top: 2px; }
.sw-error { font-size: 12px; color: #e03131; margin-top: 2px; }
.sw-error:empty { display: none; }

.sw-inline-form { display: inline; }
.sw-toggle { width: 48px; height: 26px; border-radius: 13px; border: none; padding: 0;
             background: var(--online); position: relative; flex-shrink: 0; cursor: pointer; }
.sw-toggle.off { background: var(--offline); }
.sw-toggle:disabled { background: #eef1f4; cursor: not-allowed; }
.sw-toggle::after { content: ""; position: absolute; top: 2px; right: 2px; width: 22px; height: 22px;
                    border-radius: 50%; background: #fff; box-shadow: 0 1px 2px rgba(0,0,0,.2); }
.sw-toggle.off::after { right: auto; left: 2px; }

.sw-details { margin-top: 8px; }
.sw-details summary { font-size: 12px; color: var(--muted); cursor: pointer; }
.sw-window { display: flex; align-items: center; gap: 8px; padding: 8px 0;
             border-top: 1px solid #eef1f4; font-size: 13px; }
.sw-pill { background: #fff3bf; border: 1px solid var(--accent); color: #7c5e00;
           border-radius: 999px; padding: 2px 10px; font-size: 12px; white-space: nowrap; }
.sw-pill.paused { background: #eef1f4; border-color: var(--offline); color: var(--muted);
                  text-decoration: line-through; }
.sw-icon-btn { border: none; background: none; color: var(--muted); font-size: 13px;
               cursor: pointer; padding: 2px 4px; }
.sw-window .sw-inline-form:first-of-type { margin-left: auto; }
.sw-add { display: inline-block; margin-top: 10px; font-size: 13px; color: var(--muted);
          border: 1px dashed var(--offline); border-radius: 999px; padding: 4px 12px;
          cursor: pointer; text-decoration: none; }

.sw-form { background: var(--bg); border: 1px solid var(--border); border-radius: 8px;
           padding: 12px; margin-top: 10px; }
.sw-form-row { display: flex; align-items: center; gap: 8px; margin-bottom: 10px; flex-wrap: wrap; }
.sw-form-row:last-child { margin-bottom: 0; }
.sw-form-errors { font-size: 12px; color: #e03131; margin-bottom: 8px; }
.sw-time { border: 1px solid var(--border); border-radius: 6px; padding: 6px 8px; font-size: 14px;
           background: var(--card); font-variant-numeric: tabular-nums; }
.sw-day { width: 34px; height: 30px; border-radius: 6px; border: 1px solid var(--border);
          background: var(--card); color: var(--muted); font-size: 12px; display: inline-flex;
          align-items: center; justify-content: center; cursor: pointer; user-select: none; }
.sw-day input { position: absolute; opacity: 0; pointer-events: none; }
.sw-day:has(input:checked) { background: #fff3bf; border-color: var(--accent);
                             color: #7c5e00; font-weight: 600; }
.sw-btn { border-radius: 8px; padding: 7px 14px; font-size: 13px; border: 1px solid var(--accent);
          background: var(--accent); color: #fff; font-weight: 600; cursor: pointer;
          text-decoration: none; }
.sw-btn.ghost { background: var(--card); color: var(--muted); border-color: var(--border); }
.sw-hint { font-size: 11px; color: var(--muted); }
.sw-form-actions .sw-hint { margin-left: auto; }
.sw-orphan { display: flex; align-items: center; gap: 8px; }
.sw-empty { color: var(--muted); font-size: 14px; }
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `rtk bin/rails test test/controllers/switches_controller_test.rb`
Expected: PASS (4 tests)

- [ ] **Step 9: Commit**

```bash
rtk git add config/routes.rb app/controllers/switches_controller.rb app/views/switches app/views/layouts/application.html.erb app/assets/stylesheets/application.css test/controllers/switches_controller_test.rb
rtk git commit -m "Add Schalten tab with plug cards and window list"
```

---

### Task 11: PlugSwitchesController (manual switching)

**Files:**
- Create: `app/controllers/plug_switches_controller.rb`
- Test: `test/controllers/plug_switches_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

`test/controllers/plug_switches_controller_test.rb`:

```ruby
require "test_helper"

class PlugSwitchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    SwitchCommand.delete_all
    @calls = []
    @recorder = ->(plug, action, source:, mqtt_config:) { @calls << [ plug.id, action, source ] }
  end

  test "unknown plug returns 404" do
    post "/plugs/nope/switch", params: { state: "on" }
    assert_response :not_found
  end

  test "non-switchable plug returns 422" do
    post "/plugs/bkw/switch", params: { state: "on" }
    assert_response :unprocessable_entity
  end

  test "invalid state returns 422" do
    post "/plugs/fridge/switch", params: { state: "toggle" }
    assert_response :unprocessable_entity
  end

  test "valid switch calls PlugCommander and responds with a turbo stream" do
    PlugCommander.stub :switch, @recorder do
      post "/plugs/fridge/switch", params: { state: "on" }, as: :turbo_stream
    end
    assert_response :success
    assert_equal [ [ "fridge", :on, :manual ] ], @calls
    assert_match "sw_head_fridge", @response.body
    assert_equal "text/vnd.turbo-stream.html", @response.media_type
  end

  test "broker failure responds 503 with an error stream and writes no command" do
    failing = ->(*, **) { raise PlugCommander::Error, "broker down" }
    PlugCommander.stub :switch, failing do
      post "/plugs/fridge/switch", params: { state: "on" }, as: :turbo_stream
    end
    assert_response :service_unavailable
    assert_match "sw_error_fridge", @response.body
    assert_match "nicht erreichbar", @response.body
    assert_equal 0, SwitchCommand.count
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `rtk bin/rails test test/controllers/plug_switches_controller_test.rb`
Expected: FAIL — route exists (Task 10) but `PlugSwitchesController` is missing (`uninitialized constant`).

- [ ] **Step 3: Implement**

`app/controllers/plug_switches_controller.rb`:

```ruby
class PlugSwitchesController < ApplicationController
  def create
    plug = app_config.plugs.find { |p| p.id == params[:plug_id] }
    return head :not_found unless plug
    return head :unprocessable_entity unless plug.switchable
    return head :unprocessable_entity unless %w[on off].include?(params[:state])

    PlugCommander.switch(plug, params[:state].to_sym, source: :manual, mqtt_config: app_config.mqtt)
    render turbo_stream: turbo_stream.replace(
      "sw_head_#{plug.id}",
      partial: "switches/head", locals: { row: SwitchRow.build(plug) }
    )
  rescue PlugCommander::Error
    render turbo_stream: turbo_stream.update(
      "sw_error_#{plug.id}",
      "Schalten fehlgeschlagen — MQTT-Broker nicht erreichbar"
    ), status: :service_unavailable
  end
end
```

Note on semantics: the explicit `state` param (instead of "toggle") is deliberate — a stale UI cannot race into the wrong state. The success response re-renders the head from `SwitchRow` (the just-logged command makes the toggle flip optimistically); the authoritative state arrives later via Shelly status → `MqttSubscriber` → ActionCable.

- [ ] **Step 4: Run tests to verify they pass**

Run: `rtk bin/rails test test/controllers/plug_switches_controller_test.rb`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
rtk git add app/controllers/plug_switches_controller.rb test/controllers/plug_switches_controller_test.rb
rtk git commit -m "Add manual plug switching endpoint"
```

---

### Task 12: SwitchWindowsController (window CRUD)

**Files:**
- Create: `app/controllers/switch_windows_controller.rb`
- Test: `test/controllers/switch_windows_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

`test/controllers/switch_windows_controller_test.rb`:

```ruby
require "test_helper"

class SwitchWindowsControllerTest < ActionDispatch::IntegrationTest
  setup { SwitchWindow.delete_all }

  def valid_params
    { switch_window: { on_at_time: "18:00", off_at_time: "23:00", days: [ "", "1", "2" ] } }
  end

  test "new renders the inline editor" do
    get "/plugs/fridge/switch_windows/new", as: :turbo_stream
    assert_response :success
    assert_match "sw_editor_fridge", @response.body
    assert_match "switch_window[days][]", @response.body
  end

  test "create saves a window and re-renders the windows region" do
    post "/plugs/fridge/switch_windows", params: valid_params, as: :turbo_stream
    assert_response :success
    w = SwitchWindow.last
    assert_equal [ "fridge", 1080, 1380, [ 1, 2 ] ], [ w.plug_id, w.on_at, w.off_at, w.days ]
    assert_match "sw_windows_fridge", @response.body
  end

  test "create with no days re-renders the form with errors and 422" do
    post "/plugs/fridge/switch_windows",
         params: { switch_window: { on_at_time: "18:00", off_at_time: "23:00", days: [ "" ] } },
         as: :turbo_stream
    assert_response :unprocessable_entity
    assert_equal 0, SwitchWindow.count
    assert_match "Wochentag", @response.body
  end

  test "create for unknown plug returns 404, for non-switchable 422" do
    post "/plugs/nope/switch_windows", params: valid_params, as: :turbo_stream
    assert_response :not_found
    post "/plugs/bkw/switch_windows", params: valid_params, as: :turbo_stream
    assert_response :unprocessable_entity
  end

  test "update pauses a window via enabled param" do
    w = SwitchWindow.create!(plug_id: "fridge", on_at: 1080, off_at: 1380, days: [ 1 ])
    patch "/plugs/fridge/switch_windows/#{w.id}",
          params: { switch_window: { enabled: "false" } }, as: :turbo_stream
    assert_response :success
    refute w.reload.enabled
  end

  test "edit renders the form for an existing window" do
    w = SwitchWindow.create!(plug_id: "fridge", on_at: 1080, off_at: 1380, days: [ 1 ])
    get "/plugs/fridge/switch_windows/#{w.id}/edit", as: :turbo_stream
    assert_response :success
    assert_match "18:00", @response.body
  end

  test "destroy removes the window" do
    w = SwitchWindow.create!(plug_id: "fridge", on_at: 1080, off_at: 1380, days: [ 1 ])
    delete "/plugs/fridge/switch_windows/#{w.id}", as: :turbo_stream
    assert_response :success
    assert_equal 0, SwitchWindow.count
  end

  test "destroy works for orphaned windows" do
    w = SwitchWindow.create!(plug_id: "gone", on_at: 60, off_at: 120, days: [ 1 ])
    delete "/plugs/gone/switch_windows/#{w.id}", as: :turbo_stream
    assert_response :success
    assert_equal 0, SwitchWindow.count
    assert_match "orphan_window_#{w.id}", @response.body
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `rtk bin/rails test test/controllers/switch_windows_controller_test.rb`
Expected: FAIL with `uninitialized constant SwitchWindowsController`

- [ ] **Step 3: Implement**

`app/controllers/switch_windows_controller.rb`:

```ruby
class SwitchWindowsController < ApplicationController
  before_action :set_plug, except: :destroy

  def new
    window = SwitchWindow.new(plug_id: @plug.id, days: [])
    render turbo_stream: turbo_stream.update(
      "sw_editor_#{@plug.id}",
      partial: "switches/window_form", locals: { plug: @plug, window: window }
    )
  end

  def create
    window = SwitchWindow.new(window_params.merge(plug_id: @plug.id))
    if window.save
      render_windows
    else
      render turbo_stream: turbo_stream.update(
        "sw_editor_#{@plug.id}",
        partial: "switches/window_form", locals: { plug: @plug, window: window }
      ), status: :unprocessable_entity
    end
  end

  def edit
    window = SwitchWindow.find(params[:id])
    render turbo_stream: turbo_stream.replace(
      helpers.dom_id(window),
      partial: "switches/window_form", locals: { plug: @plug, window: window }
    )
  end

  def update
    window = SwitchWindow.find(params[:id])
    if window.update(window_params)
      render_windows
    else
      render turbo_stream: turbo_stream.replace(
        helpers.dom_id(window),
        partial: "switches/window_form", locals: { plug: @plug, window: window }
      ), status: :unprocessable_entity
    end
  end

  def destroy
    window = SwitchWindow.find(params[:id])
    window.destroy!
    plug = find_plug
    if plug&.switchable
      @plug = plug
      render_windows
    else
      render turbo_stream: turbo_stream.remove("orphan_window_#{window.id}")
    end
  end

  private

  def set_plug
    @plug = find_plug
    return head :not_found unless @plug
    head :unprocessable_entity unless @plug.switchable
  end

  def find_plug
    app_config.plugs.find { |p| p.id == params[:plug_id] }
  end

  def window_params
    params.require(:switch_window).permit(:on_at_time, :off_at_time, :enabled, days: [])
  end

  # Re-render windows AND head: the next-edge in the status line may have changed.
  def render_windows
    row = SwitchRow.build(@plug)
    render turbo_stream: [
      turbo_stream.replace("sw_windows_#{@plug.id}",
                           partial: "switches/windows",
                           locals: { plug: @plug, windows: row.windows }),
      turbo_stream.replace("sw_head_#{@plug.id}",
                           partial: "switches/head", locals: { row: row })
    ]
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rtk bin/rails test test/controllers/switch_windows_controller_test.rb`
Expected: PASS (8 tests)

- [ ] **Step 5: Commit**

```bash
rtk git add app/controllers/switch_windows_controller.rb test/controllers/switch_windows_controller_test.rb
rtk git commit -m "Add time window CRUD with inline turbo-stream editor"
```

---

### Task 13: Stimulus live updates

**Files:**
- Create: `app/javascript/controllers/switches_controller.js`

No automated test (matches existing JS controllers, which are untested). Auto-registered by filename via `eagerLoadControllersFrom` — no registration step needed.

- [ ] **Step 1: Implement the controller**

`app/javascript/controllers/switches_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

// Connects to data-controller="switches" on the Schalten tab.
// Applies live wattage and output state from the existing "dashboard"
// ActionCable broadcasts (see MqttSubscriber) to the plug cards.
export default class extends Controller {
  connect() {
    this.subscription = consumer.subscriptions.create("DashboardChannel", {
      received: (data) => this.handleBroadcast(data),
    })
  }

  disconnect() {
    this.subscription?.unsubscribe()
  }

  handleBroadcast(data) {
    if (!Array.isArray(data.plugs)) return
    data.plugs.forEach((plug) => this.updateCard(plug))
  }

  updateCard(plug) {
    const card = this.element.querySelector(`[data-plug-id="${plug.plug_id}"]`)
    if (!card) return

    const watt = card.querySelector(`[data-switches-watt="${plug.plug_id}"]`)
    if (watt && typeof plug.apower_w === "number") {
      watt.textContent = `· ${Math.round(plug.apower_w)} W`
    }

    if (typeof plug.output === "boolean") {
      const toggle = card.querySelector("button.sw-toggle")
      if (toggle) {
        toggle.classList.toggle("off", !plug.output)
        toggle.disabled = false
        // Keep the form posting the opposite of the confirmed state.
        const form = toggle.closest("form")
        if (form) form.action = form.action.replace(/state=(on|off)/, `state=${plug.output ? "off" : "on"}`)
        // Authoritative state arrived — clear any stale error.
        const error = card.querySelector(".sw-error")
        if (error) error.textContent = ""
      }
      card.classList.remove("sw-offline")
    }
  }
}
```

- [ ] **Step 2: Run the full test suite**

Run: `rtk bin/rails test`
Expected: PASS, no regressions.

- [ ] **Step 3: Manual smoke test (requires local broker/dev setup)**

Run `bin/dev`, open `http://localhost:3000/switches`:
- Tab renders, nav shows "Schalten" highlighted.
- Create a window 18:00–23:00 Mo–Fr → amber pill appears, status line shows "nächste Schaltung".
- Pause → pill struck through. Edit → inline form prefilled. Delete → pill gone.
- With a real Shelly + broker: toggle switches the plug; wattage and toggle state update within ~5 s via ActionCable.

- [ ] **Step 4: Commit**

```bash
rtk git add app/javascript/controllers/switches_controller.js
rtk git commit -m "Add live updates for the Schalten tab"
```

---

## Self-review (done while writing)

- **Spec coverage:** config flag (T1), data model incl. all four tables (T2–T4), edge PORO incl. DST/midnight/collapse (T5), PlugCommander with driver dispatch + log-after-success (T6), tick job with watermark/first-run/collapse/manual-wins/frozen-watermark (T7), MqttSubscriber output + broadcast (T8), status line semantics (T9), tab UI variant C with pills/inline editor/offline/orphans (T10), explicit-state manual endpoint with Turbo error handling (T11), window CRUD incl. pause + orphan delete (T12), live updates (T13). recurring.yml every minute (T7). "Creating a window inside it does not fire the past start edge" needs no code: edges before the watermark are never replayed, and `edges_between` is evaluated against time, not window creation — covered by the boundary tests in T5.
- **Out of scope honored:** no FRITZ switching (commander raises for `fritz_dect`), no Govee, no automations, no external API, no reconciler.
- **Type consistency check:** `PlugCommander.switch(plug, action, source:, mqtt_config:)` used identically in T7 and T11; `SwitchEdgeCalculator::Edge(plug_id, action, at)` consumed in T7/T9/T10 helper; `SwitchRow` fields match between T9 (definition), T10 (views), T11/T12 (rebuilds); turbo target ids (`sw_head_`, `sw_windows_`, `sw_editor_`, `sw_error_`, `orphan_window_`) consistent across T10–T12.

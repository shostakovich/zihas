# Solakon PV Overview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a dedicated Solakon/PV page with live energy flow, EPS outside-socket control, zero-export runtime pause/resume, panel/storage details, Solakon history, balance rows, status messages, and plush battery visuals.

**Architecture:** Keep Modbus register knowledge inside `SolakonClient` as declarative field specs plus small decode helpers, so reads describe intent instead of repeating register plumbing. Keep fast live control data in `SolakonReading`, add `SolakonSnapshot` as the 10-minute history/detail source, reuse the dashboard energy-flow SVG through a shared partial, and render history with Chart.js in the existing `chart-card`/`chart-frame` report style.

**Tech Stack:** Rails 8.1, ActiveRecord, ActiveJob, Minitest, Stimulus, Chart.js via importmap, ActionCable dashboard refreshes, Propshaft assets, existing Ziwoas CSS components.

---

## File Structure

- Modify `lib/solakon_client.rb`: add table-driven fast/snapshot field specs, reusable register decode helpers, EPS write helpers, and human-readable status/alarm decoding while keeping register addresses out of UI/application code.
- Modify `app/models/solakon_reading.rb`: extend the fast live model with voltage/current/temperature/status/alarm fields needed by the page and control path.
- Create `db/migrate/*_extend_solakon_readings_for_live_details.rb`: nullable fast live columns.
- Create `db/migrate/*_create_solakon_snapshots.rb`: slow snapshot table with panel, storage, EPS, status/alarm, grid, and energy-counter fields.
- Create `app/models/solakon_snapshot.rb`: validations, range scopes, counter-delta helpers, panel helpers, storage/card helpers, and status-message helpers.
- Create `app/jobs/solakon_snapshot_job.rb`: 10-minute slow snapshot collection that does not trigger zero-export writes.
- Modify `config/recurring.yml`: schedule `SolakonSnapshotJob` every 10 minutes.
- Modify `app/jobs/solakon_monitor_job.rb`: persist the new fast live fields when available.
- Create `db/migrate/*_create_solakon_control_states.rb`: singleton persistent runtime state for Auto-Regelung pause/resume.
- Create `app/models/solakon_control_state.rb`: singleton runtime control state with config-aware active predicate.
- Modify `app/jobs/zero_export_tick_job.rb`: require both config master flag and runtime state before writing zero-export commands.
- Modify `test/jobs/zero_export_tick_job_test.rb`: cover runtime pause/resume in addition to config master disable.
- Modify `lib/config_loader.rb` only if tests reveal missing `solakon.control_enabled`; current branch already has it.
- Create `app/models/solakon_history.rb`: builds chart payload, selected range, and balance rows from `SolakonSnapshot`.
- Create `app/controllers/solakon_controller.rb`: renders page and serves `/solakon/history.json`.
- Create `app/controllers/solakon_controls_controller.rb`: direct EPS and Auto-Regelung toggle endpoints.
- Modify `config/routes.rb`: add `/solakon`, `/solakon/history`, `/solakon/eps`, and `/solakon/auto_regulation` routes.
- Modify `app/views/layouts/application.html.erb`: add primary nav item labelled `PV` using a new plush nav asset; update mobile nav grid from 5 to 6 columns.
- Create `app/views/shared/_energy_flow.html.erb`: dashboard/Solakon reusable energy-flow SVG partial with configurable Stimulus target prefix, icons, labels, and battery asset.
- Modify `app/views/dashboard/index.html.erb`: render the shared energy-flow partial and use the new normal plush battery in the hero.
- Create `app/views/solakon/index.html.erb`: single continuous Solakon page with live flow, controls, panel cards, storage cards, graph/balance, and status/details.
- Create `app/javascript/controllers/solakon_controller.js`: live flow rendering, Chart.js combined graph, range chips, balance row updates, and resilient toggle behavior.
- Modify `app/javascript/controllers/dashboard_controller.js`: no behavior rewrite; keep target names aligned with shared partial.
- Modify `app/assets/stylesheets/application.css`: Solakon page layout, control cards, panel/storage cards, balance progressbars, disabled/error states, 6-item bottom nav.
- Add `app/assets/images/nav_pv_plush.webp`: navigation icon.
- Add `app/assets/images/solakon_battery_normal.webp`, `solakon_battery_charging.webp`, `solakon_battery_low.webp`, `solakon_battery_hot.webp`, `solakon_battery_cold.webp`, `solakon_battery_fault.webp`: plush battery family based on the reference image.
- Test files:
  - `test/solakon_client_test.rb`
  - `test/models/solakon_reading_test.rb`
  - `test/models/solakon_snapshot_test.rb`
  - `test/models/solakon_control_state_test.rb`
  - `test/models/solakon_history_test.rb`
  - `test/jobs/solakon_monitor_job_test.rb`
  - `test/jobs/solakon_snapshot_job_test.rb`
  - `test/jobs/zero_export_tick_job_test.rb`
  - `test/controllers/solakon_controller_test.rb`
  - `test/controllers/solakon_controls_controller_test.rb`
  - `test/controllers/dashboard_controller_test.rb`
  - `test/controllers/reports_controller_test.rb`
  - `test/system/mobile_navigation_test.rb`

## Global Constraints

- Use user-facing labels in the UI: `Außensteckdose`, `Auto-Regelung`, `Batteriegesundheit`, `PV`, `Akku`, `Netz`.
- Do not show Modbus register addresses, bit names, raw protocol names, `EPS`, or `SOH` in the main UI.
- Do not show Panel 3/4 cards in version 1, but store PV3/PV4 columns for future use.
- Do not show `Ladezyklen`; the protocol does not provide charge cycles.
- Direct EPS switching goes through `SolakonClient`, not `PlugCommander`.
- `solakon.control_enabled` remains the master flag. Runtime Auto-Regelung can pause a permitted config, but cannot enable control when config disables it.
- Use Chart.js, existing `chart-card`/`chart-frame`, and report-style progressbar rows.
- Keep the fast Solakon tick lean; only add values needed for live/control/status. Historical cards and summaries come from `SolakonSnapshot`.
- Solakon reads must be DRY: field addresses/scales live in `SolakonClient::FIELD_SPECS`, raw conversion lives in `decode_register_value`, and callers use named fields, not repeated `read_holding_registers` plus inline math.
- Commit after each task. Keep commits small enough that a failed task can be reverted without disturbing other layers.

---

## Task 1: Add SolakonClient Fast Detail And EPS Interfaces

**Files:**
- Modify: `lib/solakon_client.rb`
- Test: `test/solakon_client_test.rb`

**Interfaces:**
- Extend `SolakonClient::State` with `battery_voltage_v`, `battery_current_a`, `inverter_temperature_c`, `status1`, `status3`, `alarm1`, `alarm2`, `alarm3`, `eps_enabled`, `eps_voltage_v`, `eps_power_w`.
- Add `SolakonClient#read_snapshot`.
- Add `SolakonClient#set_eps_output!(enabled:)`.
- Add `SolakonClient#decode_status_messages(status1:, status3:, alarm1:, alarm2:, alarm3:, bms_faults:)`.

- [ ] **Step 1: Write failing client tests**

Append to `test/solakon_client_test.rb`:

```ruby
def test_read_state_includes_fast_detail_and_eps_values
  slave = FakeSlave.new(holdings: {
    [ 39424, 1 ] => [ 55 ],
    [ 39248, 2 ] => [ 0, 300 ],
    [ 39279, 8 ] => [ 0, 100, 0, 50, 0, 0, 0, 0 ],
    [ 39230, 2 ] => [ 0xFFFF, 0xFF38 ],
    [ 37617, 1 ] => [ 423 ],
    [ 39227, 1 ] => [ 512 ],
    [ 39228, 2 ] => [ 0xFFFF, 0xF830 ],
    [ 39141, 1 ] => [ 341 ],
    [ 39063, 1 ] => [ 0b0000_0100 ],
    [ 39065, 2 ] => [ 0, 1 ],
    [ 39067, 1 ] => [ 0 ],
    [ 39068, 1 ] => [ 0b1000 ],
    [ 39069, 1 ] => [ 0 ],
    [ 46613, 1 ] => [ SolakonClient::EPS_OUTPUT_VALUES.fetch(:eps) ],
    [ 39201, 1 ] => [ 2301 ],
    [ 39216, 2 ] => [ 0, 125 ]
  })

  state = client_for(slave).read_state

  assert_in_delta 51.2, state.battery_voltage_v, 0.001
  assert_in_delta(-2.0, state.battery_current_a, 0.001)
  assert_in_delta 34.1, state.inverter_temperature_c, 0.001
  assert_equal 0b0000_0100, state.status1
  assert_equal 1, state.status3
  assert_equal 0b1000, state.alarm2
  assert_equal true, state.eps_enabled
  assert_in_delta 230.1, state.eps_voltage_v, 0.001
  assert_equal 125, state.eps_power_w
end

def test_set_eps_output_writes_directly_to_solakon_register
  slave = FakeSlave.new

  client_for(slave).set_eps_output!(enabled: true)
  client_for(slave).set_eps_output!(enabled: false)

  assert_equal [
    [ :single, SolakonClient::WRITE_REGISTERS.fetch(:eps_output), SolakonClient::EPS_OUTPUT_VALUES.fetch(:eps) ],
    [ :single, SolakonClient::WRITE_REGISTERS.fetch(:eps_output), SolakonClient::EPS_OUTPUT_VALUES.fetch(:off) ]
  ], slave.writes
end

def test_status_messages_are_human_readable
  messages = SolakonClient.decode_status_messages(
    status1: 0b0100,
    status3: 0,
    alarm1: 0,
    alarm2: 0b1000,
    alarm3: 0,
    bms_faults: [ 0, 0, 0, 0, 0, 0 ]
  )

  assert_includes messages, "Wechselrichter in Betrieb"
  assert_includes messages, "Temperatur zu hoch"
  assert messages.none? { |message| message.match?(/390|Alarm 2|Bit/) }
end
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
rtk bin/rails test test/solakon_client_test.rb
```

Expected: FAIL because the struct members, EPS value map, field specs, detail reads, and decoder do not exist.

- [ ] **Step 3: Implement declarative register specs, struct fields, and EPS writer**

In `lib/solakon_client.rb`, keep read addresses in a field-spec hash instead of scattering `REG_*` constants through the class. Leave write-only control registers as named constants where they already exist, and add EPS output to a write-register hash:

```ruby
WRITE_REGISTERS = {
  eps_output: 46613
}.freeze

EPS_OUTPUT_VALUES = {
  off: 0,
  eps: 2
}.freeze

FAST_FIELD_SPECS = {
  battery_soc: { addr: 39424, type: :i16 },
  active_power_w: { addr: 39248, count: 2, type: :i32 },
  battery_power_w: { addr: 39230, count: 2, type: :i32 },
  battery_temperature_c: { addr: 37617, type: :i16, scale: 10.0 },
  battery_voltage_v: { addr: 39227, type: :i16, scale: 10.0 },
  battery_current_a: { addr: 39228, count: 2, type: :i32, scale: 1000.0 },
  inverter_temperature_c: { addr: 39141, type: :i16, scale: 10.0 },
  status1: { addr: 39063, type: :u16 },
  status3: { addr: 39065, count: 2, type: :u32 },
  alarm1: { addr: 39067, type: :u16 },
  alarm2: { addr: 39068, type: :u16 },
  alarm3: { addr: 39069, type: :u16 },
  eps_mode: { addr: 46613, type: :u16 },
  eps_voltage_v: { addr: 39201, type: :u16, scale: 10.0 },
  eps_power_w: { addr: 39216, count: 2, type: :i32 }
}.freeze

FIELD_SPECS = {
  fast: FAST_FIELD_SPECS
}.freeze

GROUPED_READ_SPECS = {
  pv_power: { addr: 39279, count: -> { PV_STRINGS * 2 } }
}.freeze
```

Extend the struct:

```ruby
State = Struct.new(:battery_soc, :active_power_w, :pv_power_w, :battery_power_w,
                   :battery_temperature_c, :battery_voltage_v, :battery_current_a,
                   :inverter_temperature_c, :status1, :status3, :alarm1, :alarm2,
                   :alarm3, :eps_enabled, :eps_voltage_v, :eps_power_w,
                   keyword_init: true)
```

Add a small read/decode pipeline. This is the key DRY abstraction for all current and future Solakon reads:

```ruby
def read_fields(slave, group)
  FIELD_SPECS.fetch(group).transform_values { |spec| read_field(slave, spec) }
end

def read_field(slave, spec)
  regs = slave.read_holding_registers(spec.fetch(:addr), spec.fetch(:count, 1))
  value = decode_register_value(regs, spec.fetch(:type))
  scale = spec.fetch(:scale, 1.0)
  value = value / scale if scale != 1.0
  spec[:map] ? spec.fetch(:map).call(value) : value
end

def decode_register_value(regs, type)
  case type
  when :u16 then regs.first.to_i
  when :i16 then to_i16(regs.first)
  when :u32 then to_u32(regs)
  when :i32 then to_i32(regs)
  else raise Error, "unknown register type: #{type}"
  end
end

def to_u32(regs)
  ((regs[0] & 0xFFFF) << 16) | (regs[1] & 0xFFFF)
end
```

Then make `read_state_from` read like prose:

```ruby
def read_state_from(slave)
  fields = read_fields(slave, :fast)

  State.new(
    **fields.slice(:battery_soc, :active_power_w, :battery_power_w,
                   :battery_temperature_c, :battery_voltage_v, :battery_current_a,
                   :inverter_temperature_c, :status1, :status3, :alarm1, :alarm2,
                   :alarm3, :eps_voltage_v, :eps_power_w),
    pv_power_w: read_pv_power_w(slave),
    eps_enabled: fields.fetch(:eps_mode) == EPS_OUTPUT_VALUES.fetch(:eps)
  )
end

def read_pv_power_w(slave)
  regs = read_register_group(slave, :pv_power)
  (0...PV_STRINGS).sum { |idx| decode_register_value(regs[idx * 2, 2], :i32) }
end

def read_register_group(slave, key)
  spec = GROUPED_READ_SPECS.fetch(key)
  count = spec.fetch(:count)
  slave.read_holding_registers(spec.fetch(:addr), count.respond_to?(:call) ? count.call : count)
end
```

Add public writer:

```ruby
def set_eps_output!(enabled:)
  value = enabled ? EPS_OUTPUT_VALUES.fetch(:eps) : EPS_OUTPUT_VALUES.fetch(:off)
  with_slave { |slave| slave.write_holding_register(WRITE_REGISTERS.fetch(:eps_output), value) }
rescue StandardError => e
  raise Error, e.message
end
```

- [ ] **Step 4: Add human-readable status decoder**

Add this class method to `SolakonClient`:

```ruby
def self.decode_status_messages(status1:, status3:, alarm1:, alarm2:, alarm3:, bms_faults: [])
  messages = []
  messages << "Wechselrichter bereit" if (status1.to_i & 0b0001).positive?
  messages << "Wechselrichter in Betrieb" if (status1.to_i & 0b0100).positive?
  messages << "Wechselrichter meldet Fehler" if (status1.to_i & 0b0100_0000).positive?
  messages << "Inselbetrieb aktiv" if (status3.to_i & 0b0001).positive?

  alarm_map = {
    alarm1: {
      0 => "PV-Spannung zu hoch",
      1 => "DC-Lichtbogenfehler",
      2 => "PV-String verpolt",
      8 => "Netzausfall",
      9 => "Netzspannung auffällig",
      11 => "Netzfrequenz auffällig",
      14 => "Ausgangsstrom zu hoch",
      15 => "DC-Anteil im Ausgangsstrom zu groß"
    },
    alarm2: {
      0 => "Fehlerstrom auffällig",
      1 => "Erdung auffällig",
      2 => "Isolationswiderstand zu niedrig",
      3 => "Temperatur zu hoch",
      9 => "Energiespeicher auffällig",
      10 => "Inselbetrieb erkannt",
      14 => "Außensteckdose überlastet"
    },
    alarm3: {
      3 => "Lüfter auffällig",
      4 => "Energiespeicher verpolt",
      9 => "Zählerverbindung verloren",
      10 => "Batteriemanagement nicht erreichbar"
    }
  }

  { alarm1: alarm1.to_i, alarm2: alarm2.to_i, alarm3: alarm3.to_i }.each do |key, value|
    alarm_map.fetch(key).each do |bit, label|
      messages << label if (value & (1 << bit)).positive?
    end
  end

  messages << "Batterie-Warnung" if bms_faults.any? { |fault| fault.to_i.positive? }
  messages.presence || [ "Alles ruhig" ]
end
```

- [ ] **Step 5: Run tests and fix existing fixture holdings**

Run:

```bash
rtk bin/rails test test/solakon_client_test.rb
```

Expected: FAIL in older tests if their `FakeSlave` holdings lack the newly read registers.

Add a helper to merge default detail holdings:

```ruby
def default_detail_holdings
  {
    [ 39227, 1 ] => [ 512 ],
    [ 39228, 2 ] => [ 0, 0 ],
    [ 39141, 1 ] => [ 300 ],
    [ 39063, 1 ] => [ 0 ],
    [ 39065, 2 ] => [ 0, 0 ],
    [ 39067, 1 ] => [ 0 ],
    [ 39068, 1 ] => [ 0 ],
    [ 39069, 1 ] => [ 0 ],
    [ 46613, 1 ] => [ 0 ],
    [ 39201, 1 ] => [ 0 ],
    [ 39216, 2 ] => [ 0, 0 ]
  }
end
```

Use `sensor_holdings(min_soc: 10).merge(default_detail_holdings)` in tests that call `read_state`.

- [ ] **Step 6: Verify client tests pass**

Run:

```bash
rtk bin/rails test test/solakon_client_test.rb
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
rtk git add lib/solakon_client.rb test/solakon_client_test.rb
rtk git commit -m "feat: add Solakon detail and EPS client helpers"
```

---

## Task 2: Persist Fast Live Detail Fields

**Files:**
- Create: `db/migrate/*_extend_solakon_readings_for_live_details.rb`
- Modify: `app/models/solakon_reading.rb`
- Modify: `app/jobs/solakon_monitor_job.rb`
- Test: `test/models/solakon_reading_test.rb`, `test/jobs/solakon_monitor_job_test.rb`

**Interfaces:**
- `SolakonReading` gains optional numeric fields: `battery_voltage_v`, `battery_current_a`, `inverter_temperature_c`, `eps_voltage_v`, `eps_power_w`.
- `SolakonReading` gains optional integer fields: `status1`, `status3`, `alarm1`, `alarm2`, `alarm3`.
- `SolakonReading` gains optional boolean field: `eps_enabled`.
- `SolakonReading#status_messages` returns human-readable messages through `SolakonClient.decode_status_messages`.

- [ ] **Step 1: Write failing model tests**

Append to `test/models/solakon_reading_test.rb`:

```ruby
test "fast live detail fields are optional but validated by type" do
  reading = SolakonReading.new(
    taken_at: Time.current,
    active_power_w: 1,
    pv_power_w: 2,
    battery_power_w: 3,
    battery_soc_pct: 55,
    battery_voltage_v: "full",
    battery_current_a: "fast",
    inverter_temperature_c: "warm",
    eps_power_w: "on",
    status1: "ok"
  )

  assert_not reading.valid?
  assert_includes reading.errors[:battery_voltage_v], "is not a number"
  assert_includes reading.errors[:battery_current_a], "is not a number"
  assert_includes reading.errors[:inverter_temperature_c], "is not a number"
  assert_includes reading.errors[:eps_power_w], "is not a number"
  assert_includes reading.errors[:status1], "is not a number"
end

test "status_messages are user-facing" do
  reading = SolakonReading.new(status1: 0b0100, status3: 0, alarm1: 0, alarm2: 0b1000, alarm3: 0)

  assert_includes reading.status_messages, "Wechselrichter in Betrieb"
  assert_includes reading.status_messages, "Temperatur zu hoch"
  assert reading.status_messages.none? { |message| message.match?(/SOH|EPS|390|Alarm 2|Bit/) }
end
```

- [ ] **Step 2: Write failing monitor test updates**

In `test/jobs/solakon_monitor_job_test.rb`, extend `state`:

```ruby
SolakonClient::State.new(
  battery_soc: 55,
  active_power_w: 123,
  pv_power_w: 456,
  battery_power_w: -78,
  battery_temperature_c: 42.3,
  battery_voltage_v: 51.2,
  battery_current_a: -1.5,
  inverter_temperature_c: 34.1,
  status1: 4,
  status3: 0,
  alarm1: 0,
  alarm2: 8,
  alarm3: 0,
  eps_enabled: true,
  eps_voltage_v: 230.1,
  eps_power_w: 125
)
```

Add assertions in `"persists reading when monitoring_enabled true"`:

```ruby
assert_in_delta 51.2, reading.battery_voltage_v, 0.001
assert_in_delta(-1.5, reading.battery_current_a, 0.001)
assert_in_delta 34.1, reading.inverter_temperature_c, 0.001
assert_equal 4, reading.status1
assert_equal 0, reading.status3
assert_equal 0, reading.alarm1
assert_equal 8, reading.alarm2
assert_equal 0, reading.alarm3
assert_equal true, reading.eps_enabled
assert_in_delta 230.1, reading.eps_voltage_v, 0.001
assert_equal 125, reading.eps_power_w
```

- [ ] **Step 3: Run tests and verify failure**

Run:

```bash
rtk bin/rails test test/models/solakon_reading_test.rb test/jobs/solakon_monitor_job_test.rb
```

Expected: FAIL because the columns and `status_messages` are missing.

- [ ] **Step 4: Create migration**

Run:

```bash
rtk bin/rails generate migration ExtendSolakonReadingsForLiveDetails battery_voltage_v:float battery_current_a:float inverter_temperature_c:float status1:integer status3:integer alarm1:integer alarm2:integer alarm3:integer eps_enabled:boolean eps_voltage_v:float eps_power_w:float
```

Edit the generated migration body to keep all fields nullable:

```ruby
class ExtendSolakonReadingsForLiveDetails < ActiveRecord::Migration[8.1]
  def change
    change_table :solakon_readings do |t|
      t.float :battery_voltage_v
      t.float :battery_current_a
      t.float :inverter_temperature_c
      t.integer :status1
      t.integer :status3
      t.integer :alarm1
      t.integer :alarm2
      t.integer :alarm3
      t.boolean :eps_enabled
      t.float :eps_voltage_v
      t.float :eps_power_w
    end
  end
end
```

- [ ] **Step 5: Implement model validations and status messages**

In `app/models/solakon_reading.rb`, add:

```ruby
validates :battery_voltage_v, :battery_current_a, :inverter_temperature_c,
          :eps_voltage_v, :eps_power_w,
          numericality: true, allow_nil: true
validates :status1, :status3, :alarm1, :alarm2, :alarm3,
          numericality: { only_integer: true }, allow_nil: true

def status_messages
  SolakonClient.decode_status_messages(
    status1: status1,
    status3: status3,
    alarm1: alarm1,
    alarm2: alarm2,
    alarm3: alarm3,
    bms_faults: []
  )
end
```

Add `require "solakon_client"` at the top if the model cannot resolve the constant in tests.

- [ ] **Step 6: Persist new state fields in monitor job**

In `app/jobs/solakon_monitor_job.rb`, extend the `SolakonReading.create!` call:

```ruby
SolakonReading.create!(
  taken_at: now,
  active_power_w: state.active_power_w,
  pv_power_w: state.pv_power_w,
  battery_power_w: state.battery_power_w,
  battery_soc_pct: state.battery_soc,
  battery_temperature_c: state.battery_temperature_c,
  battery_voltage_v: state.battery_voltage_v,
  battery_current_a: state.battery_current_a,
  inverter_temperature_c: state.inverter_temperature_c,
  status1: state.status1,
  status3: state.status3,
  alarm1: state.alarm1,
  alarm2: state.alarm2,
  alarm3: state.alarm3,
  eps_enabled: state.eps_enabled,
  eps_voltage_v: state.eps_voltage_v,
  eps_power_w: state.eps_power_w
)
```

- [ ] **Step 7: Migrate and verify tests**

Run:

```bash
rtk bin/rails db:migrate
rtk bin/rails db:migrate RAILS_ENV=test
rtk bin/rails test test/models/solakon_reading_test.rb test/jobs/solakon_monitor_job_test.rb
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
rtk git add db/migrate db/schema.rb app/models/solakon_reading.rb app/jobs/solakon_monitor_job.rb test/models/solakon_reading_test.rb test/jobs/solakon_monitor_job_test.rb
rtk git commit -m "feat: persist Solakon live detail fields"
```

---

## Task 3: Add Slow Solakon Snapshot Model And Collection Job

**Files:**
- Modify: `lib/solakon_client.rb`
- Create: `db/migrate/*_create_solakon_snapshots.rb`
- Create: `app/models/solakon_snapshot.rb`
- Create: `app/jobs/solakon_snapshot_job.rb`
- Modify: `config/recurring.yml`
- Test: `test/solakon_client_test.rb`, `test/models/solakon_snapshot_test.rb`, `test/jobs/solakon_snapshot_job_test.rb`

**Interfaces:**
- `SolakonClient::SnapshotData` contains slow panel, battery, EPS, status/alarm, grid, and energy-counter values.
- `SolakonSnapshot.latest` returns newest snapshot.
- `SolakonSnapshot#connected_panels` returns only PV1/PV2 for version 1 when power/voltage/current are present.
- `SolakonSnapshot#status_messages` returns human-readable messages.

- [ ] **Step 1: Write failing client snapshot test**

Append to `test/solakon_client_test.rb`:

```ruby
def test_read_snapshot_decodes_panel_storage_energy_and_status_values
  slave = FakeSlave.new(holdings: default_detail_holdings.merge({
    [ 39070, 8 ] => [ 410, 512, 405, 488, 0, 0, 0, 0 ],
    [ 39279, 8 ] => [ 0, 210, 0, 198, 0, 0, 0, 0 ],
    [ 37609, 1 ] => [ 513 ],
    [ 37610, 1 ] => [ 42 ],
    [ 37611, 1 ] => [ 248 ],
    [ 37617, 1 ] => [ 423 ],
    [ 37618, 1 ] => [ 211 ],
    [ 37624, 1 ] => [ 97 ],
    [ 37626, 6 ] => [ 0, 0, 0, 0, 0, 0 ],
    [ 37632, 1 ] => [ 1234 ],
    [ 37633, 1 ] => [ 512 ],
    [ 37635, 1 ] => [ 19200 ],
    [ 39141, 1 ] => [ 341 ],
    [ 39168, 2 ] => [ 0xFFFF, 0xFF9C ],
    [ 39216, 2 ] => [ 0, 125 ],
    [ 39601, 20 ] => [ 0, 12345, 0, 345, 0, 6789, 0, 120, 0, 4567, 0, 98, 0, 2222, 0, 55, 0, 3333, 0, 77 ]
  }))

  snapshot = client_for(slave).read_snapshot

  assert_equal 4, snapshot.panels.length
  assert_in_delta 41.0, snapshot.panels[0].voltage_v, 0.001
  assert_in_delta 5.12, snapshot.panels[0].current_a, 0.001
  assert_equal 210, snapshot.panels[0].power_w
  assert_in_delta 51.3, snapshot.battery_voltage_v, 0.001
  assert_in_delta 4.2, snapshot.battery_current_a, 0.001
  assert_equal 97, snapshot.battery_health_pct
  assert_in_delta 123.4, snapshot.remaining_energy_wh, 0.001
  assert_in_delta 51.2, snapshot.full_charge_capacity_ah, 0.001
  assert_in_delta 1920.0, snapshot.design_energy_wh, 0.001
  assert_equal 100, snapshot.grid_power_w
  assert_in_delta 123.45, snapshot.pv_total_kwh, 0.001
  assert_in_delta 67.89, snapshot.battery_charge_total_kwh, 0.001
  assert_in_delta 45.67, snapshot.battery_discharge_total_kwh, 0.001
  assert_in_delta 22.22, snapshot.grid_export_total_kwh, 0.001
  assert_in_delta 33.33, snapshot.grid_import_total_kwh, 0.001
end
```

- [ ] **Step 2: Run client test and verify failure**

Run:

```bash
rtk bin/rails test test/solakon_client_test.rb
```

Expected: FAIL because `read_snapshot` and snapshot structs are missing.

- [ ] **Step 3: Extend the field specs and implement snapshot reader through shared helpers**

In `lib/solakon_client.rb`, add the snapshot structs, then edit the existing `FIELD_SPECS`/`GROUPED_READ_SPECS` definitions so they include slow snapshot fields. Do not append a second constant definition below the first one; the final class should have one field-spec map and one grouped-read map:

```ruby
PanelData = Struct.new(:index, :voltage_v, :current_a, :power_w, keyword_init: true)
SnapshotData = Struct.new(
  :panels, :battery_voltage_v, :battery_current_a, :battery_temperature_c,
  :battery_min_temperature_c, :battery_health_pct, :remaining_energy_wh,
  :full_charge_capacity_ah, :design_energy_wh, :inverter_temperature_c,
  :grid_power_w, :eps_enabled, :eps_voltage_v, :eps_power_w,
  :status1, :status3, :alarm1, :alarm2, :alarm3, :bms_faults,
  :pv_total_kwh, :battery_charge_total_kwh, :battery_discharge_total_kwh,
  :grid_export_total_kwh, :grid_import_total_kwh,
  keyword_init: true
)

FIELD_SPECS = {
  fast: FAST_FIELD_SPECS,
  snapshot: FAST_FIELD_SPECS.merge(
    battery_voltage_v: { addr: 37609, type: :u16, scale: 10.0 },
    battery_current_a: { addr: 37610, type: :i16, scale: 10.0 },
    battery_temperature_c: { addr: 37611, type: :i16, scale: 10.0 },
    battery_min_temperature_c: { addr: 37618, type: :i16, scale: 10.0 },
    battery_health_pct: { addr: 37624, type: :u16 },
    remaining_energy_wh: { addr: 37632, type: :u16, scale: 10.0 },
    full_charge_capacity_ah: { addr: 37633, type: :u16, scale: 10.0 },
    design_energy_wh: { addr: 37635, type: :u16, scale: 10.0 },
    grid_power_w: { addr: 39168, count: 2, type: :i32, map: ->(value) { -value } }
  )
}.freeze

GROUPED_READ_SPECS = {
  pv_power: { addr: 39279, count: -> { PV_STRINGS * 2 } },
  pv_voltage_current: { addr: 39070, count: -> { PV_STRINGS * 2 } },
  bms_faults: { addr: 37626, count: 6 },
  energy_counters: { addr: 39601, count: 20 }
}.freeze
```

Add the public method:

```ruby
def read_snapshot
  with_slave { |slave| read_snapshot_from(slave) }
end
```

Implement snapshot reading in small named helpers. `read_snapshot_from` should contain no register addresses and no inline scaling math:

```ruby
def read_snapshot_from(slave)
  fields = read_fields(slave, :snapshot)
  groups = read_snapshot_groups(slave)
  energy = decode_energy_counters(groups.fetch(:energy_counters))

  SnapshotData.new(
    **fields.slice(:battery_voltage_v, :battery_current_a, :battery_temperature_c,
                   :battery_min_temperature_c, :battery_health_pct, :remaining_energy_wh,
                   :full_charge_capacity_ah, :design_energy_wh, :inverter_temperature_c,
                   :grid_power_w, :eps_voltage_v, :eps_power_w,
                   :status1, :status3, :alarm1, :alarm2, :alarm3),
    panels: read_panels(groups),
    eps_enabled: fields.fetch(:eps_mode) == EPS_OUTPUT_VALUES.fetch(:eps),
    bms_faults: groups.fetch(:bms_faults),
    **energy
  )
end

def read_snapshot_groups(slave)
  %i[pv_voltage_current pv_power bms_faults energy_counters].to_h do |key|
    [ key, read_register_group(slave, key) ]
  end
end

def read_panels(groups)
  vi = groups.fetch(:pv_voltage_current)
  powers = groups.fetch(:pv_power)

  (0...PV_STRINGS).map do |idx|
    PanelData.new(
      index: idx + 1,
      voltage_v: scaled(decode_register_value([ vi[idx * 2] ], :i16), 10),
      current_a: scaled(decode_register_value([ vi[idx * 2 + 1] ], :i16), 100),
      power_w: decode_register_value(powers[idx * 2, 2], :i32)
    )
  end
end

def decode_energy_counters(regs)
  {
    pv_total_kwh: energy_counter_kwh(regs[0, 2]),
    battery_charge_total_kwh: energy_counter_kwh(regs[4, 2]),
    battery_discharge_total_kwh: energy_counter_kwh(regs[8, 2]),
    grid_export_total_kwh: energy_counter_kwh(regs[12, 2]),
    grid_import_total_kwh: energy_counter_kwh(regs[16, 2])
  }
end

def energy_counter_kwh(regs)
  scaled(decode_register_value(regs, :u32), 100)
end

def scaled(value, divisor)
  value.to_f / divisor
end
```

`read_panels` is the only remaining grouped-read special case because PV voltage/current and power live in two compact register ranges; keeping that translation behind one helper avoids four future copies when PV3/PV4 are enabled.

- [ ] **Step 4: Verify client snapshot test**

Run:

```bash
rtk bin/rails test test/solakon_client_test.rb
```

Expected: PASS.

- [ ] **Step 5: Write failing model tests**

Create `test/models/solakon_snapshot_test.rb`:

```ruby
require "test_helper"

class SolakonSnapshotTest < ActiveSupport::TestCase
  test "requires taken_at and validates numeric fields" do
    snapshot = SolakonSnapshot.new(pv1_power_w: "bright")

    assert_not snapshot.valid?
    assert_includes snapshot.errors[:taken_at], "can't be blank"
    assert_includes snapshot.errors[:pv1_power_w], "is not a number"
  end

  test "connected_panels returns only panel one and two when connected" do
    snapshot = SolakonSnapshot.new(
      pv1_power_w: 210, pv1_voltage_v: 41.0, pv1_current_a: 5.12,
      pv2_power_w: 198, pv2_voltage_v: 40.5, pv2_current_a: 4.88,
      pv3_power_w: 50, pv3_voltage_v: 40.0, pv3_current_a: 1.0,
      pv4_power_w: 60, pv4_voltage_v: 40.0, pv4_current_a: 1.5
    )

    assert_equal [
      { index: 1, label: "Panel 1", power_w: 210.0, voltage_v: 41.0, current_a: 5.12 },
      { index: 2, label: "Panel 2", power_w: 198.0, voltage_v: 40.5, current_a: 4.88 }
    ], snapshot.connected_panels
  end

  test "status_messages delegates to user-facing decoder" do
    snapshot = SolakonSnapshot.new(status1: 4, status3: 0, alarm1: 0, alarm2: 8, alarm3: 0, bms_faults: [ 0, 0, 0, 0, 0, 0 ])

    assert_includes snapshot.status_messages, "Wechselrichter in Betrieb"
    assert_includes snapshot.status_messages, "Temperatur zu hoch"
    assert snapshot.status_messages.none? { |message| message.match?(/SOH|EPS|390|Alarm 2|Bit/) }
  end
end
```

- [ ] **Step 6: Write failing job test**

Create `test/jobs/solakon_snapshot_job_test.rb`:

```ruby
require "test_helper"

class SolakonSnapshotJobTest < ActiveJob::TestCase
  class FakeClient
    attr_reader :calls

    def initialize(snapshot: nil, fail: false)
      @snapshot = snapshot
      @fail = fail
      @calls = []
    end

    def read_snapshot
      @calls << :read_snapshot
      raise SolakonClient::Error, "down" if @fail
      @snapshot
    end
  end

  Sol = Struct.new(:host, :port, :unit_id, :monitoring_enabled, :control_enabled, :stale_after_s, keyword_init: true)
  Cfg = Struct.new(:solakon, keyword_init: true)

  setup { SolakonSnapshot.delete_all }

  def config(monitoring_enabled: true, solakon: true)
    Cfg.new(solakon: (Sol.new(host: "h", port: 502, unit_id: 1, monitoring_enabled: monitoring_enabled, control_enabled: false, stale_after_s: 120) if solakon))
  end

  def snapshot_data
    SolakonClient::SnapshotData.new(
      panels: [
        SolakonClient::PanelData.new(index: 1, voltage_v: 41.0, current_a: 5.12, power_w: 210),
        SolakonClient::PanelData.new(index: 2, voltage_v: 40.5, current_a: 4.88, power_w: 198),
        SolakonClient::PanelData.new(index: 3, voltage_v: 0.0, current_a: 0.0, power_w: 0),
        SolakonClient::PanelData.new(index: 4, voltage_v: 0.0, current_a: 0.0, power_w: 0)
      ],
      battery_voltage_v: 51.3,
      battery_current_a: 4.2,
      battery_temperature_c: 24.8,
      battery_min_temperature_c: 21.1,
      battery_health_pct: 97,
      remaining_energy_wh: 123.4,
      full_charge_capacity_ah: 51.2,
      design_energy_wh: 1920.0,
      inverter_temperature_c: 34.1,
      grid_power_w: 100,
      eps_enabled: true,
      eps_voltage_v: 230.1,
      eps_power_w: 125,
      status1: 4,
      status3: 0,
      alarm1: 0,
      alarm2: 0,
      alarm3: 0,
      bms_faults: [ 0, 0, 0, 0, 0, 0 ],
      pv_total_kwh: 123.45,
      battery_charge_total_kwh: 67.89,
      battery_discharge_total_kwh: 45.67,
      grid_export_total_kwh: 22.22,
      grid_import_total_kwh: 33.33
    )
  end

  test "persists slow snapshot when monitoring is enabled" do
    now = Time.zone.local(2026, 6, 20, 12, 0, 0)
    client = FakeClient.new(snapshot: snapshot_data)

    ConfigLoader.stub(:app_config, config) do
      assert_difference -> { SolakonSnapshot.count }, 1 do
        SolakonSnapshotJob.new.perform(client: client, now: now)
      end
    end

    row = SolakonSnapshot.last
    assert_equal [ :read_snapshot ], client.calls
    assert_equal now, row.taken_at
    assert_equal 210, row.pv1_power_w
    assert_equal 198, row.pv2_power_w
    assert_equal 97, row.battery_health_pct
    assert_equal true, row.eps_enabled
    assert_in_delta 123.45, row.pv_total_kwh, 0.001
  end

  test "does not read when Solakon monitoring is disabled" do
    client = FakeClient.new(snapshot: snapshot_data)

    ConfigLoader.stub(:app_config, config(monitoring_enabled: false)) do
      assert_no_difference -> { SolakonSnapshot.count } do
        SolakonSnapshotJob.new.perform(client: client)
      end
    end

    assert_empty client.calls
  end

  test "read failure is logged and does not persist" do
    client = FakeClient.new(fail: true)

    ConfigLoader.stub(:app_config, config) do
      assert_no_difference -> { SolakonSnapshot.count } do
        assert_nothing_raised { SolakonSnapshotJob.new.perform(client: client) }
      end
    end
  end
end
```

- [ ] **Step 7: Run model/job tests and verify failure**

Run:

```bash
rtk bin/rails test test/models/solakon_snapshot_test.rb test/jobs/solakon_snapshot_job_test.rb
```

Expected: FAIL because table, model, and job are missing.

- [ ] **Step 8: Generate and edit migration**

Run:

```bash
rtk bin/rails generate model SolakonSnapshot taken_at:datetime pv1_power_w:float pv1_voltage_v:float pv1_current_a:float pv2_power_w:float pv2_voltage_v:float pv2_current_a:float pv3_power_w:float pv3_voltage_v:float pv3_current_a:float pv4_power_w:float pv4_voltage_v:float pv4_current_a:float battery_voltage_v:float battery_current_a:float battery_power_w:float battery_soc_pct:integer battery_temperature_c:float battery_min_temperature_c:float battery_health_pct:integer remaining_energy_wh:float full_charge_capacity_ah:float design_energy_wh:float inverter_temperature_c:float grid_power_w:float eps_enabled:boolean eps_voltage_v:float eps_power_w:float status1:integer status3:integer alarm1:integer alarm2:integer alarm3:integer bms_faults:json pv_total_kwh:float battery_charge_total_kwh:float battery_discharge_total_kwh:float grid_export_total_kwh:float grid_import_total_kwh:float
```

Edit migration:

```ruby
class CreateSolakonSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :solakon_snapshots do |t|
      t.datetime :taken_at, null: false
      t.float :pv1_power_w
      t.float :pv1_voltage_v
      t.float :pv1_current_a
      t.float :pv2_power_w
      t.float :pv2_voltage_v
      t.float :pv2_current_a
      t.float :pv3_power_w
      t.float :pv3_voltage_v
      t.float :pv3_current_a
      t.float :pv4_power_w
      t.float :pv4_voltage_v
      t.float :pv4_current_a
      t.float :battery_voltage_v
      t.float :battery_current_a
      t.float :battery_power_w
      t.integer :battery_soc_pct
      t.float :battery_temperature_c
      t.float :battery_min_temperature_c
      t.integer :battery_health_pct
      t.float :remaining_energy_wh
      t.float :full_charge_capacity_ah
      t.float :design_energy_wh
      t.float :inverter_temperature_c
      t.float :grid_power_w
      t.boolean :eps_enabled
      t.float :eps_voltage_v
      t.float :eps_power_w
      t.integer :status1
      t.integer :status3
      t.integer :alarm1
      t.integer :alarm2
      t.integer :alarm3
      t.json :bms_faults, null: false, default: []
      t.float :pv_total_kwh
      t.float :battery_charge_total_kwh
      t.float :battery_discharge_total_kwh
      t.float :grid_export_total_kwh
      t.float :grid_import_total_kwh

      t.timestamps
    end

    add_index :solakon_snapshots, :taken_at
  end
end
```

- [ ] **Step 9: Implement model**

Set `app/models/solakon_snapshot.rb`:

```ruby
require "solakon_client"

class SolakonSnapshot < ApplicationRecord
  PANEL_FIELDS = (1..4).flat_map { |idx| [ :"pv#{idx}_power_w", :"pv#{idx}_voltage_v", :"pv#{idx}_current_a" ] }.freeze
  NUMERIC_FIELDS = (PANEL_FIELDS + %i[
    battery_voltage_v battery_current_a battery_power_w battery_temperature_c
    battery_min_temperature_c remaining_energy_wh full_charge_capacity_ah
    design_energy_wh inverter_temperature_c grid_power_w eps_voltage_v eps_power_w
    pv_total_kwh battery_charge_total_kwh battery_discharge_total_kwh
    grid_export_total_kwh grid_import_total_kwh
  ]).freeze
  INTEGER_FIELDS = %i[battery_soc_pct battery_health_pct status1 status3 alarm1 alarm2 alarm3].freeze

  validates :taken_at, presence: true
  validates(*NUMERIC_FIELDS, numericality: true, allow_nil: true)
  validates(*INTEGER_FIELDS, numericality: { only_integer: true }, allow_nil: true)

  scope :newest_first, -> { order(taken_at: :desc) }
  scope :in_range, ->(from:, to:) { where(taken_at: from..to).order(:taken_at) }

  def self.latest = newest_first.first

  def connected_panels
    (1..2).filter_map do |idx|
      power = public_send(:"pv#{idx}_power_w")
      voltage = public_send(:"pv#{idx}_voltage_v")
      current = public_send(:"pv#{idx}_current_a")
      next if [ power, voltage, current ].all? { |value| value.to_f.zero? }

      { index: idx, label: "Panel #{idx}", power_w: power.to_f, voltage_v: voltage.to_f, current_a: current.to_f }
    end
  end

  def status_messages
    SolakonClient.decode_status_messages(
      status1: status1,
      status3: status3,
      alarm1: alarm1,
      alarm2: alarm2,
      alarm3: alarm3,
      bms_faults: bms_faults || []
    )
  end
end
```

- [ ] **Step 10: Implement job**

Create `app/jobs/solakon_snapshot_job.rb`:

```ruby
require "config_loader"
require "solakon_client"

class SolakonSnapshotJob < ApplicationJob
  queue_as :default

  def perform(client: nil, now: Time.current)
    config = ConfigLoader.app_config
    solakon = config.solakon

    return Rails.logger.info("solakon_snapshot: not configured") if solakon.nil?
    return Rails.logger.info("solakon_snapshot: monitoring disabled") unless solakon.monitoring_enabled

    client ||= SolakonClient.new(host: solakon.host, port: solakon.port, unit_id: solakon.unit_id)
    data = client.read_snapshot

    SolakonSnapshot.create!(snapshot_attributes(data, now))
  rescue SolakonClient::Error => e
    Rails.logger.warn("solakon_snapshot: Modbus failure: #{e.message}")
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("solakon_snapshot: invalid snapshot: #{e.record.errors.full_messages.join(", ")}")
  end

  private

  def snapshot_attributes(data, now)
    attrs = {
      taken_at: now,
      battery_voltage_v: data.battery_voltage_v,
      battery_current_a: data.battery_current_a,
      battery_temperature_c: data.battery_temperature_c,
      battery_min_temperature_c: data.battery_min_temperature_c,
      battery_health_pct: data.battery_health_pct,
      remaining_energy_wh: data.remaining_energy_wh,
      full_charge_capacity_ah: data.full_charge_capacity_ah,
      design_energy_wh: data.design_energy_wh,
      inverter_temperature_c: data.inverter_temperature_c,
      grid_power_w: data.grid_power_w,
      eps_enabled: data.eps_enabled,
      eps_voltage_v: data.eps_voltage_v,
      eps_power_w: data.eps_power_w,
      status1: data.status1,
      status3: data.status3,
      alarm1: data.alarm1,
      alarm2: data.alarm2,
      alarm3: data.alarm3,
      bms_faults: data.bms_faults,
      pv_total_kwh: data.pv_total_kwh,
      battery_charge_total_kwh: data.battery_charge_total_kwh,
      battery_discharge_total_kwh: data.battery_discharge_total_kwh,
      grid_export_total_kwh: data.grid_export_total_kwh,
      grid_import_total_kwh: data.grid_import_total_kwh
    }

    data.panels.each do |panel|
      attrs[:"pv#{panel.index}_power_w"] = panel.power_w
      attrs[:"pv#{panel.index}_voltage_v"] = panel.voltage_v
      attrs[:"pv#{panel.index}_current_a"] = panel.current_a
    end

    attrs
  end
end
```

- [ ] **Step 11: Schedule recurring job**

In `config/recurring.yml`, add under the shared schedule:

```yaml
  solakon_snapshot:
    class: SolakonSnapshotJob
    queue: default
    schedule: every 10 minutes
```

- [ ] **Step 12: Migrate and verify tests**

Run:

```bash
rtk bin/rails db:migrate
rtk bin/rails db:migrate RAILS_ENV=test
rtk bin/rails test test/solakon_client_test.rb test/models/solakon_snapshot_test.rb test/jobs/solakon_snapshot_job_test.rb
```

Expected: PASS.

- [ ] **Step 13: Commit**

```bash
rtk git add lib/solakon_client.rb db/migrate db/schema.rb app/models/solakon_snapshot.rb app/jobs/solakon_snapshot_job.rb config/recurring.yml test/solakon_client_test.rb test/models/solakon_snapshot_test.rb test/jobs/solakon_snapshot_job_test.rb
rtk git commit -m "feat: collect Solakon slow snapshots"
```

---

## Task 4: Add Persistent Auto-Regelung Runtime State

**Files:**
- Create: `db/migrate/*_create_solakon_control_states.rb`
- Create: `app/models/solakon_control_state.rb`
- Modify: `app/jobs/zero_export_tick_job.rb`
- Test: `test/models/solakon_control_state_test.rb`, `test/jobs/zero_export_tick_job_test.rb`

**Interfaces:**
- `SolakonControlState.current` returns a singleton row.
- `SolakonControlState#auto_regulation_active?` is true when not paused.
- `ZeroExportTickJob` writes control only when config `control_enabled` is true and runtime state is active.

- [ ] **Step 1: Write failing model test**

Create `test/models/solakon_control_state_test.rb`:

```ruby
require "test_helper"

class SolakonControlStateTest < ActiveSupport::TestCase
  setup { SolakonControlState.delete_all if defined?(SolakonControlState) }

  test "current returns a singleton defaulting to active auto regulation" do
    state = SolakonControlState.current

    assert_equal state, SolakonControlState.current
    assert_equal false, state.auto_regulation_paused
    assert state.auto_regulation_active?
  end

  test "pause and resume change persistent runtime state" do
    state = SolakonControlState.current

    state.pause_auto_regulation!
    assert_not SolakonControlState.current.auto_regulation_active?

    state.resume_auto_regulation!
    assert SolakonControlState.current.auto_regulation_active?
  end
end
```

- [ ] **Step 2: Write failing job test**

Append to `test/jobs/zero_export_tick_job_test.rb`:

```ruby
test "no-op when runtime auto regulation is paused even if config permits control" do
  SolakonControlState.current.pause_auto_regulation!
  now = Time.zone.local(2026, 6, 20, 12, 0, 0)
  Sample.create!(plug_id: "fridge", ts: now.to_i - 5, apower_w: 250, aenergy_wh: 1)
  client = FakeClient.new(state: healthy_state)

  run_job(client: client, now: now)

  assert_empty client.calls
end
```

- [ ] **Step 3: Run tests and verify failure**

Run:

```bash
rtk bin/rails test test/models/solakon_control_state_test.rb test/jobs/zero_export_tick_job_test.rb
```

Expected: FAIL because the table/model and runtime gate are missing.

- [ ] **Step 4: Generate migration and model**

Run:

```bash
rtk bin/rails generate model SolakonControlState auto_regulation_paused:boolean
```

Edit migration:

```ruby
class CreateSolakonControlStates < ActiveRecord::Migration[8.1]
  def change
    create_table :solakon_control_states do |t|
      t.boolean :auto_regulation_paused, null: false, default: false

      t.timestamps
    end
  end
end
```

Set `app/models/solakon_control_state.rb`:

```ruby
class SolakonControlState < ApplicationRecord
  def self.current
    first_or_create!
  end

  def auto_regulation_active?
    !auto_regulation_paused?
  end

  def pause_auto_regulation!
    update!(auto_regulation_paused: true)
  end

  def resume_auto_regulation!
    update!(auto_regulation_paused: false)
  end
end
```

- [ ] **Step 5: Gate ZeroExportTickJob**

In `app/jobs/zero_export_tick_job.rb`, after the existing config control check:

```ruby
return Rails.logger.info("zero_export: runtime paused") unless SolakonControlState.current.auto_regulation_active?
```

Keep the existing line:

```ruby
return Rails.logger.info("zero_export: control disabled") unless solakon.control_enabled
```

before the runtime check so config remains the master switch.

- [ ] **Step 6: Migrate and verify tests**

Run:

```bash
rtk bin/rails db:migrate
rtk bin/rails db:migrate RAILS_ENV=test
rtk bin/rails test test/models/solakon_control_state_test.rb test/jobs/zero_export_tick_job_test.rb
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
rtk git add db/migrate db/schema.rb app/models/solakon_control_state.rb app/jobs/zero_export_tick_job.rb test/models/solakon_control_state_test.rb test/jobs/zero_export_tick_job_test.rb
rtk git commit -m "feat: add Solakon auto regulation runtime state"
```

---

## Task 5: Add Solakon History Builder

**Files:**
- Create: `app/models/solakon_history.rb`
- Test: `test/models/solakon_history_test.rb`

**Interfaces:**
- `SolakonHistory.new(range_key:, now:).payload` returns chart data for `24h`, `7d`, and `30d`.
- Chart labels are compact.
- Dataset labels are exactly `PV`, `Akku`, `Netz`, `0 W`.
- Balance rows are `PV-Erzeugung`, `Akku geladen`, `Akku entladen`, `Netzbezug`, `Netzeinspeisung`, `Ø Netzleistung`.

- [ ] **Step 1: Write failing tests**

Create `test/models/solakon_history_test.rb`:

```ruby
require "test_helper"

class SolakonHistoryTest < ActiveSupport::TestCase
  setup { SolakonSnapshot.delete_all }

  test "payload builds signed chart series and balance rows from snapshots" do
    travel_to Time.zone.local(2026, 6, 20, 12, 0, 0) do
      SolakonSnapshot.create!(
        taken_at: 2.hours.ago,
        pv1_power_w: 100,
        pv2_power_w: 50,
        battery_power_w: 20,
        grid_power_w: 30,
        pv_total_kwh: 10.0,
        battery_charge_total_kwh: 5.0,
        battery_discharge_total_kwh: 3.0,
        grid_import_total_kwh: 7.0,
        grid_export_total_kwh: 1.0
      )
      SolakonSnapshot.create!(
        taken_at: 1.hour.ago,
        pv1_power_w: 150,
        pv2_power_w: 75,
        battery_power_w: -40,
        grid_power_w: -60,
        pv_total_kwh: 11.2,
        battery_charge_total_kwh: 5.4,
        battery_discharge_total_kwh: 3.3,
        grid_import_total_kwh: 7.5,
        grid_export_total_kwh: 1.2
      )

      payload = SolakonHistory.new(range_key: "24h", now: Time.current).payload

      assert_equal "24h", payload.fetch(:range)
      assert_equal [ "PV", "Akku", "Netz", "0 W" ], payload.dig(:chart, :datasets).map { |dataset| dataset.fetch(:label) }
      assert_equal [ 150.0, 225.0 ], payload.dig(:chart, :datasets).first.fetch(:data)
      assert_equal [ 20.0, -40.0 ], payload.dig(:chart, :datasets)[1].fetch(:data)
      assert_equal [ 30.0, -60.0 ], payload.dig(:chart, :datasets)[2].fetch(:data)
      assert_equal [ 0, 0 ], payload.dig(:chart, :datasets)[3].fetch(:data)

      rows = payload.fetch(:balance_rows)
      assert_equal [ "PV-Erzeugung", "Akku geladen", "Akku entladen", "Netzbezug", "Netzeinspeisung", "Ø Netzleistung" ], rows.map { |row| row.fetch(:label) }
      assert_equal "1,20 kWh", rows[0].fetch(:value)
      assert_equal "0,40 kWh", rows[1].fetch(:value)
      assert_equal "0,30 kWh", rows[2].fetch(:value)
      assert_equal "0,50 kWh", rows[3].fetch(:value)
      assert_equal "0,20 kWh", rows[4].fetch(:value)
    end
  end

  test "empty payload is stable" do
    payload = SolakonHistory.new(range_key: "7d", now: Time.zone.local(2026, 6, 20, 12, 0, 0)).payload

    assert_equal "7d", payload.fetch(:range)
    assert_equal [], payload.dig(:chart, :labels)
    assert_equal "Keine Solakon-Historie", payload.fetch(:message)
  end
end
```

- [ ] **Step 2: Run test and verify failure**

Run:

```bash
rtk bin/rails test test/models/solakon_history_test.rb
```

Expected: FAIL because `SolakonHistory` does not exist.

- [ ] **Step 3: Implement history builder**

Create `app/models/solakon_history.rb`:

```ruby
class SolakonHistory
  RANGES = {
    "24h" => 24.hours,
    "7d" => 7.days,
    "30d" => 30.days
  }.freeze

  def initialize(range_key:, now: Time.current)
    @range_key = RANGES.key?(range_key) ? range_key : "24h"
    @now = now
  end

  def payload
    rows = SolakonSnapshot.in_range(from: from_time, to: @now).to_a
    return empty_payload if rows.empty?

    {
      range: @range_key,
      chart: chart_payload(rows),
      balance_rows: balance_rows(rows),
      message: nil
    }
  end

  private

  def from_time
    @now - RANGES.fetch(@range_key)
  end

  def empty_payload
    {
      range: @range_key,
      chart: {
        labels: [],
        datasets: [
          { label: "PV", data: [] },
          { label: "Akku", data: [] },
          { label: "Netz", data: [] },
          { label: "0 W", data: [] }
        ]
      },
      balance_rows: [],
      message: "Keine Solakon-Historie"
    }
  end

  def chart_payload(rows)
    {
      labels: rows.map { |row| label_for(row.taken_at) },
      datasets: [
        { label: "PV", data: rows.map { |row| (row.pv1_power_w.to_f + row.pv2_power_w.to_f).round(1) } },
        { label: "Akku", data: rows.map { |row| row.battery_power_w.to_f.round(1) } },
        { label: "Netz", data: rows.map { |row| row.grid_power_w.to_f.round(1) } },
        { label: "0 W", data: rows.map { 0 } }
      ]
    }
  end

  def label_for(time)
    @range_key == "24h" ? time.strftime("%H:%M") : time.strftime("%d.%m.")
  end

  def balance_rows(rows)
    first = rows.first
    last = rows.last
    deltas = {
      pv: delta(first.pv_total_kwh, last.pv_total_kwh),
      charge: delta(first.battery_charge_total_kwh, last.battery_charge_total_kwh),
      discharge: delta(first.battery_discharge_total_kwh, last.battery_discharge_total_kwh),
      import: delta(first.grid_import_total_kwh, last.grid_import_total_kwh),
      export: delta(first.grid_export_total_kwh, last.grid_export_total_kwh)
    }
    avg_grid_w = rows.map { |row| row.grid_power_w.to_f }.sum / rows.length
    max = [ deltas.values.max.to_f, avg_grid_w.abs / 1000.0, 0.001 ].max

    [
      row("PV-Erzeugung", deltas.fetch(:pv), max, :solar),
      row("Akku geladen", deltas.fetch(:charge), max, :battery),
      row("Akku entladen", deltas.fetch(:discharge), max, :battery),
      row("Netzbezug", deltas.fetch(:import), max, :grid),
      row("Netzeinspeisung", deltas.fetch(:export), max, :grid),
      {
        label: "Ø Netzleistung",
        value: "#{format_decimal(avg_grid_w.round)} W",
        share: ((avg_grid_w.abs / 1000.0) / max * 100).round(1),
        role: "grid"
      }
    ]
  end

  def delta(first_value, last_value)
    [ last_value.to_f - first_value.to_f, 0.0 ].max.round(2)
  end

  def row(label, kwh, max, role)
    { label: label, value: "#{format_decimal(kwh)} kWh", share: (kwh / max * 100).round(1), role: role.to_s }
  end

  def format_decimal(value)
    format("%.2f", value).sub(".", ",")
  end
end
```

- [ ] **Step 4: Verify test**

Run:

```bash
rtk bin/rails test test/models/solakon_history_test.rb
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add app/models/solakon_history.rb test/models/solakon_history_test.rb
rtk git commit -m "feat: build Solakon history payload"
```

---

## Task 6: Add Solakon Routes, Page Controller, And History JSON

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/solakon_controller.rb`
- Create: `app/views/solakon/index.html.erb`
- Test: `test/controllers/solakon_controller_test.rb`

**Interfaces:**
- `GET /solakon` renders a page titled `PV`.
- `GET /solakon/history.json?range=24h|7d|30d` returns `SolakonHistory` payload.
- The page is a single continuous page, not tabs.

- [ ] **Step 1: Write failing controller tests**

Create `test/controllers/solakon_controller_test.rb`:

```ruby
require "test_helper"

class SolakonControllerTest < ActionDispatch::IntegrationTest
  setup do
    SolakonReading.delete_all
    SolakonSnapshot.delete_all if defined?(SolakonSnapshot)
  end

  test "page renders single continuous Solakon overview" do
    get "/solakon"

    assert_response :success
    assert_select "h1", text: "PV", count: 1
    assert_select "[data-controller='solakon']", 1
    assert_select ".section-label", text: "Energiefluss"
    assert_select ".section-label", text: "Steuerung"
    assert_select ".section-label", text: "Panels"
    assert_select ".section-label", text: "Speicher"
    assert_select ".section-label", text: "Solakon-Verlauf"
    assert_select ".section-label", text: "Status"
    assert_select "[role='tablist']", count: 0
    assert_no_match(/SOH|EPS|46613|39067|Modbus/, response.body)
    assert_match(/Außensteckdose/, response.body)
    assert_match(/Auto-Regelung/, response.body)
    assert_match(/Batteriegesundheit/, response.body)
  end

  test "history endpoint returns selected range payload" do
    SolakonSnapshot.create!(taken_at: 10.minutes.ago, pv1_power_w: 100, pv2_power_w: 50, battery_power_w: 20, grid_power_w: 30)

    get "/solakon/history.json", params: { range: "24h" }

    assert_response :success
    data = response.parsed_body
    assert_equal "24h", data["range"]
    assert_equal [ "PV", "Akku", "Netz", "0 W" ], data.dig("chart", "datasets").map { |dataset| dataset.fetch("label") }
  end
end
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
rtk bin/rails test test/controllers/solakon_controller_test.rb
```

Expected: FAIL because routes/controller/view are missing.

- [ ] **Step 3: Add routes**

In `config/routes.rb`, add near other top-level pages:

```ruby
get "/solakon", to: "solakon#index", as: :solakon
get "/solakon/history", to: "solakon#history", as: :solakon_history
```

- [ ] **Step 4: Implement controller**

Create `app/controllers/solakon_controller.rb`:

```ruby
class SolakonController < ApplicationController
  def index
    config = app_config.solakon
    @control_enabled = config&.control_enabled || false
    @runtime_state = SolakonControlState.current
    @latest_reading = SolakonReading.newest_first.first
    @latest_snapshot = SolakonSnapshot.latest
    @history_payload = SolakonHistory.new(range_key: "24h").payload
  end

  def history
    render json: SolakonHistory.new(range_key: params[:range].to_s).payload
  end
end
```

- [ ] **Step 5: Add minimal view scaffold**

Create `app/views/solakon/index.html.erb`:

```erb
<% content_for :title, "PV" %>
<% content_for :body_class, "page-solakon" %>

<h1>PV</h1>

<div class="solakon-page" data-controller="solakon">
  <h2 class="section-label">Energiefluss</h2>
  <div class="chart-card energy-flow-card">
    <p class="muted-text">Live-Werte erscheinen, sobald Solakon Daten liefert.</p>
  </div>

  <h2 class="section-label">Steuerung</h2>
  <section class="solakon-control-grid">
    <article class="tile solakon-control-card" data-solakon-target="epsCard">
      <div class="tile-label">Außensteckdose</div>
      <div class="tile-value" data-solakon-target="epsState"><%= @latest_reading&.eps_enabled ? "An" : "Aus" %></div>
      <p class="muted-text">Notstrom-Ausgang</p>
    </article>
    <article class="tile solakon-control-card" data-solakon-target="autoRegulationCard">
      <div class="tile-label">Auto-Regelung</div>
      <div class="tile-value" data-solakon-target="autoRegulationState"><%= @control_enabled && @runtime_state.auto_regulation_active? ? "Aktiv" : "Pausiert" %></div>
      <p class="muted-text"><%= @control_enabled ? "hält Einspeisung nahe 0 W" : "in Konfiguration deaktiviert" %></p>
    </article>
  </section>

  <h2 class="section-label">Panels</h2>
  <section class="tiles solakon-panel-grid">
    <% (@latest_snapshot&.connected_panels || []).each do |panel| %>
      <article class="tile">
        <div class="tile-label"><%= panel.fetch(:label) %></div>
        <div class="tile-value"><%= number_with_precision(panel.fetch(:power_w), precision: 0, delimiter: ".", separator: ",") %> W</div>
      </article>
    <% end %>
  </section>

  <h2 class="section-label">Speicher</h2>
  <section class="tiles solakon-storage-grid">
    <article class="tile">
      <div class="tile-label">Batteriegesundheit</div>
      <div class="tile-value"><%= @latest_snapshot&.battery_health_pct || "—" %> %</div>
    </article>
  </section>

  <h2 class="section-label">Solakon-Verlauf</h2>
  <section class="chart-card">
    <div class="preset-actions" role="group" aria-label="Zeitraum">
      <button type="button" class="preset-link active" data-solakon-range-param="24h" data-action="solakon#selectRange">Letzte 24 h</button>
      <button type="button" class="preset-link" data-solakon-range-param="7d" data-action="solakon#selectRange">Letzte 7 Tage</button>
      <button type="button" class="preset-link" data-solakon-range-param="30d" data-action="solakon#selectRange">Letzte 30 Tage</button>
    </div>
    <div class="chart-frame">
      <canvas data-solakon-target="historyCanvas"></canvas>
    </div>
    <p class="muted-text">Akku: + lädt, − entlädt. Netz: + Bezug, − Einspeisung.</p>
  </section>

  <h2 class="section-label">Status</h2>
  <section class="chart-card solakon-status-card">
    <% (@latest_snapshot&.status_messages || [ "Alles ruhig" ]).each do |message| %>
      <p class="muted-text"><%= message %></p>
    <% end %>
  </section>

  <script type="application/json" data-solakon-target="historyPayload"><%= raw json_escape(@history_payload.to_json) %></script>
</div>
```

- [ ] **Step 6: Verify controller tests**

Run:

```bash
rtk bin/rails test test/controllers/solakon_controller_test.rb
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
rtk git add config/routes.rb app/controllers/solakon_controller.rb app/views/solakon/index.html.erb test/controllers/solakon_controller_test.rb
rtk git commit -m "feat: add Solakon PV overview route"
```

---

## Task 7: Add Direct Solakon Control Endpoints

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/solakon_controls_controller.rb`
- Test: `test/controllers/solakon_controls_controller_test.rb`

**Interfaces:**
- `PATCH /solakon/eps` writes EPS state directly through `SolakonClient#set_eps_output!`.
- `PATCH /solakon/auto_regulation` pauses/resumes runtime state only when config permits control.
- Responses are JSON for Stimulus toggles.

- [ ] **Step 1: Write failing controller tests**

Create `test/controllers/solakon_controls_controller_test.rb`:

```ruby
require "test_helper"

class SolakonControlsControllerTest < ActionDispatch::IntegrationTest
  class FakeClient
    class << self
      attr_accessor :instance
    end

    attr_reader :calls

    def initialize(host:, port:, unit_id:)
      @calls = [ [ :initialize, host, port, unit_id ] ]
      self.class.instance = self
    end

    def set_eps_output!(enabled:)
      @calls << [ :set_eps_output, enabled ]
    end
  end

  Sol = Struct.new(:host, :port, :unit_id, :monitoring_enabled, :control_enabled, :stale_after_s, keyword_init: true)
  Cfg = Struct.new(:solakon, keyword_init: true)

  setup { SolakonControlState.delete_all }

  def config(control_enabled: true, solakon: true)
    Cfg.new(solakon: (Sol.new(host: "h", port: 502, unit_id: 1, monitoring_enabled: true, control_enabled: control_enabled, stale_after_s: 120) if solakon))
  end

  test "eps endpoint writes directly through SolakonClient" do
    ConfigLoader.stub(:app_config, config) do
      SolakonClient.stub(:new, ->(host:, port:, unit_id:) { FakeClient.new(host: host, port: port, unit_id: unit_id) }) do
        patch "/solakon/eps", params: { enabled: "true" }, as: :json
      end
    end

    assert_response :success
    assert_equal true, response.parsed_body["enabled"]
    assert_equal [ [ :initialize, "h", 502, 1 ], [ :set_eps_output, true ] ], FakeClient.instance.calls
  end

  test "eps endpoint returns service unavailable on Modbus failure" do
    failing = Object.new
    def failing.set_eps_output!(enabled:) = raise SolakonClient::Error, "down"

    ConfigLoader.stub(:app_config, config) do
      SolakonClient.stub(:new, ->(**) { failing }) do
        patch "/solakon/eps", params: { enabled: "true" }, as: :json
      end
    end

    assert_response :service_unavailable
    assert_equal "Schalten fehlgeschlagen", response.parsed_body["error"]
  end

  test "auto regulation resumes and pauses when config permits control" do
    ConfigLoader.stub(:app_config, config(control_enabled: true)) do
      patch "/solakon/auto_regulation", params: { active: "false" }, as: :json
    end

    assert_response :success
    assert_equal false, response.parsed_body["active"]
    assert_not SolakonControlState.current.auto_regulation_active?

    ConfigLoader.stub(:app_config, config(control_enabled: true)) do
      patch "/solakon/auto_regulation", params: { active: "true" }, as: :json
    end

    assert_response :success
    assert_equal true, response.parsed_body["active"]
    assert SolakonControlState.current.auto_regulation_active?
  end

  test "auto regulation cannot enable when config disables control" do
    SolakonControlState.current.pause_auto_regulation!

    ConfigLoader.stub(:app_config, config(control_enabled: false)) do
      patch "/solakon/auto_regulation", params: { active: "true" }, as: :json
    end

    assert_response :forbidden
    assert_equal "in Konfiguration deaktiviert", response.parsed_body["error"]
    assert_not SolakonControlState.current.auto_regulation_active?
  end
end
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
rtk bin/rails test test/controllers/solakon_controls_controller_test.rb
```

Expected: FAIL because routes/controller are missing.

- [ ] **Step 3: Add routes**

In `config/routes.rb`, add:

```ruby
patch "/solakon/eps", to: "solakon_controls#eps", as: :solakon_eps
patch "/solakon/auto_regulation", to: "solakon_controls#auto_regulation", as: :solakon_auto_regulation
```

- [ ] **Step 4: Implement controller**

Create `app/controllers/solakon_controls_controller.rb`:

```ruby
require "solakon_client"

class SolakonControlsController < ApplicationController
  def eps
    solakon = app_config.solakon
    return render json: { error: "Solakon nicht konfiguriert" }, status: :service_unavailable if solakon.nil?

    enabled = ActiveModel::Type::Boolean.new.cast(params[:enabled])
    client = SolakonClient.new(host: solakon.host, port: solakon.port, unit_id: solakon.unit_id)
    client.set_eps_output!(enabled: enabled)

    render json: { enabled: enabled }
  rescue SolakonClient::Error => e
    Rails.logger.warn("solakon_controls: EPS switch failed: #{e.message}")
    render json: { error: "Schalten fehlgeschlagen" }, status: :service_unavailable
  end

  def auto_regulation
    solakon = app_config.solakon
    return render json: { error: "Solakon nicht konfiguriert" }, status: :service_unavailable if solakon.nil?
    return render json: { error: "in Konfiguration deaktiviert" }, status: :forbidden unless solakon.control_enabled

    active = ActiveModel::Type::Boolean.new.cast(params[:active])
    state = SolakonControlState.current
    active ? state.resume_auto_regulation! : state.pause_auto_regulation!

    render json: { active: state.auto_regulation_active? }
  end
end
```

- [ ] **Step 5: Verify tests**

Run:

```bash
rtk bin/rails test test/controllers/solakon_controls_controller_test.rb
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
rtk git add config/routes.rb app/controllers/solakon_controls_controller.rb test/controllers/solakon_controls_controller_test.rb
rtk git commit -m "feat: add Solakon control endpoints"
```

---

## Task 8: Extract Reusable Energy Flow Partial And Use Plush Battery

**Files:**
- Create: `app/views/shared/_energy_flow.html.erb`
- Modify: `app/views/dashboard/index.html.erb`
- Modify: `app/views/solakon/index.html.erb`
- Test: `test/controllers/dashboard_controller_test.rb`, `test/controllers/solakon_controller_test.rb`

**Interfaces:**
- Shared partial accepts `target_prefix:`, `pv_asset:`, `pv_alt:`, and `battery_asset:`.
- Dashboard keeps existing `data-dashboard-target` names.
- Solakon page gets equivalent `data-solakon-target` names.

- [ ] **Step 1: Write failing Solakon energy-flow assertions**

In `test/controllers/solakon_controller_test.rb`, add:

```ruby
test "page reuses four-node energy flow with Solakon targets" do
  get "/solakon"

  assert_response :success
  assert_select "svg[viewBox='0 0 400 320']", 1
  assert_select "[data-solakon-target='efPvW']", 1
  assert_select "[data-solakon-target='efGridW']", 1
  assert_select "[data-solakon-target='efConsumerW']", 1
  assert_select "[data-solakon-target='efBatterySoc']", 1
  assert_select "[data-solakon-target='efBatteryW']", 1
  assert_select "[data-solakon-target='efDotsSolarHome']", 1
  assert_select "image[href*='solakon_battery_normal']", minimum: 1
end
```

In `test/controllers/dashboard_controller_test.rb`, update battery image expectations from `icon_batterie` to `solakon_battery_normal` for the dashboard hero and energy-flow battery node after extraction.

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
rtk bin/rails test test/controllers/dashboard_controller_test.rb test/controllers/solakon_controller_test.rb
```

Expected: FAIL because partial and asset references are missing.

- [ ] **Step 3: Create shared partial**

Move the existing dashboard energy-flow SVG into `app/views/shared/_energy_flow.html.erb` and replace every dashboard target with dynamic target attributes. Use this pattern for each target:

```erb
<% target = ->(name) { "data-#{target_prefix}-target=\"#{name}\"".html_safe } %>
```

Example replacement:

```erb
<text <%= target.call("efPvW") %> x="200" y="102" text-anchor="middle" font-size="12" font-weight="600" fill="#7c5e00">— W</text>
```

Use these image inputs:

```erb
<image href="<%= asset_path pv_asset %>" x="184" y="55" width="32" height="32"/>
<image href="<%= asset_path "icon_netz.webp" %>" x="42" y="145" width="32" height="32"/>
<image href="<%= asset_path "icon_haus.webp" %>" x="326" y="145" width="32" height="32"/>
<image href="<%= asset_path battery_asset %>" x="184" y="235" width="32" height="32" preserveAspectRatio="xMidYMid meet"/>
```

Keep all paths, circles, clip paths, labels, and target names identical to the current dashboard SVG except for the dynamic prefix.

- [ ] **Step 4: Render partial from dashboard**

In `app/views/dashboard/index.html.erb`, replace the inline SVG inside `.energy-flow-card` with:

```erb
<%= render "shared/energy_flow",
           target_prefix: "dashboard",
           pv_asset: @dashboard_weather_asset,
           pv_alt: @dashboard_weather_alt,
           battery_asset: "solakon_battery_normal.webp" %>
```

Change the dashboard hero battery image:

```erb
<%= image_tag "solakon_battery_normal.webp", class: "hero-icon hero-icon-battery", alt: "Batterie" %>
```

- [ ] **Step 5: Render partial from Solakon page**

In `app/views/solakon/index.html.erb`, replace the introductory text in the energy-flow card with:

```erb
<%= render "shared/energy_flow",
           target_prefix: "solakon",
           pv_asset: "icon_sonne.webp",
           pv_alt: "PV",
           battery_asset: "solakon_battery_normal.webp" %>
```

- [ ] **Step 6: Add temporary asset copies for tests**

Before generated assets exist, copy the current battery icon to the new normal battery filename:

```bash
rtk cp app/assets/images/icon_batterie.webp app/assets/images/solakon_battery_normal.webp
```

This is intentionally temporary and replaced by Task 12 generated assets.

- [ ] **Step 7: Verify tests**

Run:

```bash
rtk bin/rails test test/controllers/dashboard_controller_test.rb test/controllers/solakon_controller_test.rb
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
rtk git add app/views/shared/_energy_flow.html.erb app/views/dashboard/index.html.erb app/views/solakon/index.html.erb app/assets/images/solakon_battery_normal.webp test/controllers/dashboard_controller_test.rb test/controllers/solakon_controller_test.rb
rtk git commit -m "refactor: reuse Solakon energy flow partial"
```

---

## Task 9: Complete Solakon Page Markup And Navigation

**Files:**
- Modify: `app/views/solakon/index.html.erb`
- Modify: `app/views/layouts/application.html.erb`
- Modify: `app/assets/stylesheets/application.css`
- Add: `app/assets/images/nav_pv_plush.webp`
- Test: `test/controllers/solakon_controller_test.rb`, `test/controllers/reports_controller_test.rb`, `test/system/mobile_navigation_test.rb`

**Interfaces:**
- Page order is live flow, controls, panel cards, storage cards, graph/balance, status.
- Nav label is `PV`; bottom nav has 6 columns.
- Main view does not expose register language.

- [ ] **Step 1: Extend failing markup/nav tests**

In `test/controllers/solakon_controller_test.rb`, add:

```ruby
test "page renders controls, panel, storage, balance, and status labels without protocol language" do
  SolakonSnapshot.create!(
    taken_at: Time.current,
    pv1_power_w: 210,
    pv1_voltage_v: 41.0,
    pv1_current_a: 5.12,
    pv2_power_w: 198,
    pv2_voltage_v: 40.5,
    pv2_current_a: 4.88,
    pv3_power_w: 0,
    pv3_voltage_v: 0,
    pv3_current_a: 0,
    battery_health_pct: 97,
    battery_voltage_v: 51.3,
    battery_current_a: 4.2,
    battery_temperature_c: 24.8,
    remaining_energy_wh: 123.4,
    full_charge_capacity_ah: 51.2,
    design_energy_wh: 1920.0,
    inverter_temperature_c: 34.1,
    eps_enabled: true,
    eps_voltage_v: 230.1,
    eps_power_w: 125
  )

  get "/solakon"

  assert_response :success
  assert_select ".solakon-control-card", 2
  assert_select ".solakon-panel-card", 2
  assert_select ".solakon-panel-card", text: /Panel 3/, count: 0
  assert_select ".solakon-storage-grid .tile-label", text: "Ladestand"
  assert_select ".solakon-storage-grid .tile-label", text: "Batteriegesundheit"
  assert_select ".solakon-storage-grid .tile-label", text: "Aktuelle Batterieleistung"
  assert_select ".solakon-storage-grid .tile-label", text: "Batteriespannung"
  assert_select ".solakon-storage-grid .tile-label", text: "Batteriestrom"
  assert_select ".solakon-storage-grid .tile-label", text: "Speichertemperatur"
  assert_select ".solakon-storage-grid .tile-label", text: "Ladezyklen", count: 0
  assert_select ".solakon-balance-row", minimum: 6
  assert_no_match(/SOH|EPS|Modbus|Register|39067|46613|Fault\d|Alarm \d/, response.body)
end
```

In `test/controllers/reports_controller_test.rb`, update expected nav links to include:

```ruby
solakon_path => [ "PV", "nav_pv_plush.webp" ]
```

In the CSS assertions, update:

```ruby
assert_includes stylesheet, "grid-template-columns: repeat(6, minmax(0, 1fr));"
```

In `test/system/mobile_navigation_test.rb`, add:

```ruby
assert_text "PV"
assert_equal 6, nav_box.fetch("columns")
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
rtk bin/rails test test/controllers/solakon_controller_test.rb test/controllers/reports_controller_test.rb test/system/mobile_navigation_test.rb
```

Expected: FAIL because nav, full markup, CSS, and icon are missing.

- [ ] **Step 3: Add nav icon temporary asset**

Use the sun icon until Task 12 replaces it with a proper plush asset:

```bash
rtk cp app/assets/images/icon_sonne.webp app/assets/images/nav_pv_plush.webp
```

- [ ] **Step 4: Add navigation item**

In `app/views/layouts/application.html.erb`, add the PV link between Home and Schalten:

```erb
<%= link_to solakon_path, class: [ "app-nav-link", ("active" if current_page?(solakon_path)) ] do %>
  <%= image_tag "nav_pv_plush.webp", alt: "", class: "app-nav-icon", aria: { hidden: true } %>
  <span class="app-nav-label">PV</span>
<% end %>
```

In `app/assets/stylesheets/application.css`, change the mobile nav grid:

```css
grid-template-columns: repeat(6, minmax(0, 1fr));
```

- [ ] **Step 5: Complete Solakon page view**

Replace `app/views/solakon/index.html.erb` with a full version using these ERB helper snippets:

```erb
<% latest = @latest_snapshot %>
<% reading = @latest_reading %>
<% fmt = ->(value, precision = 0) { value.nil? ? "—" : number_with_precision(value, precision: precision, delimiter: ".", separator: ",") } %>
```

Controls:

```erb
<article class="tile solakon-control-card" data-solakon-target="epsCard">
  <div class="tile-label">Außensteckdose</div>
  <div class="tile-value" data-solakon-target="epsState"><%= reading&.eps_enabled ? "An" : "Aus" %></div>
  <p class="muted-text">Notstrom-Ausgang · <span data-solakon-target="epsPower"><%= fmt.call(reading&.eps_power_w) %> W</span> · <span data-solakon-target="epsVoltage"><%= fmt.call(reading&.eps_voltage_v, 1) %> V</span></p>
  <label class="ios-toggle solakon-toggle">
    <input type="checkbox"
           <%= "checked" if reading&.eps_enabled %>
           data-solakon-target="epsToggle"
           data-action="change->solakon#toggleEps">
    <span class="ios-toggle-track"><span class="ios-toggle-thumb"></span></span>
    <span class="ios-toggle-label">Außensteckdose schalten</span>
  </label>
  <p class="solakon-control-error" data-solakon-target="epsError" hidden></p>
</article>
```

Auto-Regelung card:

```erb
<% auto_active = @control_enabled && @runtime_state.auto_regulation_active? %>
<article class="tile solakon-control-card" data-solakon-target="autoRegulationCard">
  <div class="tile-label">Auto-Regelung</div>
  <div class="tile-value" data-solakon-target="autoRegulationState"><%= auto_active ? "Aktiv" : (@control_enabled ? "Pausiert" : "Aus") %></div>
  <p class="muted-text" data-solakon-target="autoRegulationHelp"><%= @control_enabled ? "hält Einspeisung nahe 0 W" : "in Konfiguration deaktiviert" %></p>
  <label class="ios-toggle solakon-toggle <%= "is-disabled" unless @control_enabled %>">
    <input type="checkbox"
           <%= "checked" if auto_active %>
           <%= "disabled" unless @control_enabled %>
           data-solakon-target="autoRegulationToggle"
           data-action="change->solakon#toggleAutoRegulation">
    <span class="ios-toggle-track"><span class="ios-toggle-thumb"></span></span>
    <span class="ios-toggle-label">Auto-Regelung</span>
  </label>
  <p class="solakon-control-error" data-solakon-target="autoRegulationError" hidden></p>
</article>
```

Panel cards:

```erb
<section class="tiles solakon-panel-grid">
  <% (latest&.connected_panels || []).each do |panel| %>
    <article class="tile solakon-panel-card">
      <div class="tile-label"><%= panel.fetch(:label) %></div>
      <div class="tile-value"><%= fmt.call(panel.fetch(:power_w)) %> W</div>
      <p class="muted-text"><%= fmt.call(panel.fetch(:voltage_v), 1) %> V · <%= fmt.call(panel.fetch(:current_a), 2) %> A</p>
    </article>
  <% end %>
</section>
```

Storage cards:

```erb
<section class="tiles solakon-storage-grid">
  <article class="tile"><div class="tile-label">Ladestand</div><div class="tile-value"><%= reading&.battery_soc_pct || "—" %> %</div></article>
  <article class="tile"><div class="tile-label">Batteriegesundheit</div><div class="tile-value"><%= latest&.battery_health_pct || "—" %> %</div></article>
  <article class="tile"><div class="tile-label">Aktuelle Batterieleistung</div><div class="tile-value"><%= fmt.call(reading&.battery_display_power_w) %> W</div></article>
  <article class="tile"><div class="tile-label">Batteriespannung</div><div class="tile-value"><%= fmt.call(reading&.battery_voltage_v || latest&.battery_voltage_v, 1) %> V</div></article>
  <article class="tile"><div class="tile-label">Batteriestrom</div><div class="tile-value"><%= fmt.call(reading&.battery_current_a || latest&.battery_current_a, 2) %> A</div></article>
  <article class="tile"><div class="tile-label">Speichertemperatur</div><div class="tile-value"><%= fmt.call(reading&.battery_temperature_c || latest&.battery_temperature_c, 1) %> °C</div></article>
  <article class="tile"><div class="tile-label">Restenergie</div><div class="tile-value"><%= fmt.call(latest&.remaining_energy_wh, 0) %> Wh</div></article>
  <article class="tile"><div class="tile-label">Volle Kapazität</div><div class="tile-value"><%= fmt.call(latest&.full_charge_capacity_ah, 1) %> Ah</div></article>
  <article class="tile"><div class="tile-label">Auslegung</div><div class="tile-value"><%= fmt.call(latest&.design_energy_wh, 0) %> Wh</div></article>
</section>
```

Balance rows:

```erb
<div class="solakon-balance" data-solakon-target="balanceRows">
  <% @history_payload.fetch(:balance_rows).each do |row| %>
    <div class="solakon-balance-row <%= row.fetch(:role) %>">
      <span class="solakon-balance-label"><%= row.fetch(:label) %></span>
      <span class="report-ranking-bar" aria-hidden="true"><span style="width: <%= row.fetch(:share) %>%"></span></span>
      <span class="report-ranking-value"><%= row.fetch(:value) %></span>
    </div>
  <% end %>
</div>
```

Status details:

```erb
<section class="chart-card solakon-status-card">
  <% (latest&.status_messages || reading&.status_messages || [ "Alles ruhig" ]).each do |message| %>
    <p class="muted-text"><%= message %></p>
  <% end %>
  <details>
    <summary>Details</summary>
    <p class="muted-text">Wechselrichtertemperatur <%= fmt.call(reading&.inverter_temperature_c || latest&.inverter_temperature_c, 1) %> °C</p>
    <p class="muted-text">Außensteckdose <%= reading&.eps_enabled ? "bereit" : "aus" %></p>
  </details>
</section>
```

- [ ] **Step 6: Add CSS**

Append to `app/assets/stylesheets/application.css`:

```css
body.page-solakon { max-width: 1040px; }

.solakon-page { width: 100%; }
.solakon-control-grid,
.solakon-panel-grid,
.solakon-storage-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 10px;
  margin-bottom: 16px;
}
.solakon-storage-grid { grid-template-columns: repeat(3, minmax(0, 1fr)); }
.solakon-control-card .muted-text,
.solakon-panel-card .muted-text { margin: 6px 0 0; }
.solakon-toggle {
  margin-top: 10px;
  display: inline-flex;
  align-items: center;
  gap: 8px;
}
.solakon-toggle.is-disabled { opacity: 0.55; }
.solakon-control-error {
  margin: 8px 0 0;
  color: #b42318;
  font-size: 13px;
}
.solakon-balance {
  display: grid;
  gap: 8px;
  margin-top: 12px;
}
.solakon-balance-row {
  display: grid;
  grid-template-columns: minmax(9rem, 1.2fr) minmax(90px, 2fr) auto;
  gap: 8px;
  align-items: center;
  font-size: 13px;
}
.solakon-balance-label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.solakon-balance-row.solar .report-ranking-bar span { background: var(--accent); }
.solakon-balance-row.battery .report-ranking-bar span { background: #14b8a6; }
.solakon-balance-row.grid .report-ranking-bar span { background: #3b82f6; }
.solakon-status-card details {
  margin-top: 10px;
  border-top: 1px dashed var(--border);
  padding-top: 10px;
}

@media (max-width: 720px) {
  body.page-solakon { max-width: 720px; }
  .solakon-storage-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}

@media (max-width: 520px) {
  .solakon-control-grid,
  .solakon-panel-grid,
  .solakon-storage-grid { grid-template-columns: 1fr; }
  .solakon-balance-row {
    grid-template-columns: 1fr auto;
  }
  .solakon-balance-row .report-ranking-bar {
    grid-column: 1 / -1;
    order: 3;
  }
}
```

- [ ] **Step 7: Verify tests**

Run:

```bash
rtk bin/rails test test/controllers/solakon_controller_test.rb test/controllers/reports_controller_test.rb test/system/mobile_navigation_test.rb
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
rtk git add app/views/solakon/index.html.erb app/views/layouts/application.html.erb app/assets/stylesheets/application.css app/assets/images/nav_pv_plush.webp test/controllers/solakon_controller_test.rb test/controllers/reports_controller_test.rb test/system/mobile_navigation_test.rb
rtk git commit -m "feat: complete Solakon overview markup"
```

---

## Task 10: Implement Solakon Stimulus Chart, Live Flow, And Toggles

**Files:**
- Create: `app/javascript/controllers/solakon_controller.js`
- Modify: `app/views/solakon/index.html.erb`
- Test: `test/controllers/solakon_controller_test.rb`

**Interfaces:**
- `solakon_controller.js` renders one combined Chart.js graph with labels `PV`, `Akku`, `Netz`, `0 W`.
- Range chips call `/solakon/history.json?range=...` and update chart plus balance rows.
- EPS toggle reverts on failure and shows concise error near the card.
- Auto-Regelung toggle respects disabled state rendered by server.

- [ ] **Step 1: Add controller-target assertions**

Append to the first Solakon controller page test:

```ruby
assert_select "canvas[data-solakon-target='historyCanvas']", 1
assert_select "script[data-solakon-target='historyPayload']", 1
assert_select "[data-solakon-target='balanceRows']", 1
assert_select "input[data-solakon-target='epsToggle'][data-action='change->solakon#toggleEps']", 1
assert_select "input[data-solakon-target='autoRegulationToggle'][data-action='change->solakon#toggleAutoRegulation']", 1
```

- [ ] **Step 2: Run controller test and verify markup target failures**

Run:

```bash
rtk bin/rails test test/controllers/solakon_controller_test.rb
```

Expected: FAIL only for any missing Stimulus targets or actions.

- [ ] **Step 3: Fix view targets**

Ensure `app/views/solakon/index.html.erb` includes all targets asserted above. Keep the existing `historyPayload` JSON script:

```erb
<script type="application/json" data-solakon-target="historyPayload"><%= raw json_escape(@history_payload.to_json) %></script>
```

- [ ] **Step 4: Create Stimulus controller**

Create `app/javascript/controllers/solakon_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"
import "chart.js"
import consumer from "channels/consumer"

export default class extends Controller {
  static targets = [
    "historyCanvas", "historyPayload", "balanceRows",
    "epsToggle", "epsState", "epsPower", "epsVoltage", "epsError",
    "autoRegulationToggle", "autoRegulationState", "autoRegulationHelp", "autoRegulationError",
    "efPvW", "efGridW", "efConsumerW", "efBatterySoc", "efBatteryW",
    "efLineSolarHome", "efLineSolarGrid", "efLineSolarBattery",
    "efLineGridHome", "efLineGridBattery", "efLineBatteryHome",
    "efDotsSolarHome", "efDotsSolarGrid", "efDotsSolarBattery",
    "efDotsGridHome", "efDotsGridBattery", "efDotsBatteryHome",
    "efConsumerRing",
  ]

  connect() {
    this.chart = null
    this.efLastDur = {}
    this._buildChart(this._readPayload())
    this.subscription = consumer.subscriptions.create("DashboardChannel", {
      received: (data) => {
        if (data.energy_flow) this.updateEnergyFlow(data.energy_flow)
        if (data.solakon) this.fetchLive()
      },
    })
    this.fetchLive()
  }

  disconnect() {
    this.subscription?.unsubscribe()
    this.chart?.destroy()
  }

  async selectRange(event) {
    const range = event.currentTarget.dataset.solakonRangeParam
    const response = await fetch(`/solakon/history.json?range=${encodeURIComponent(range)}`)
    if (!response.ok) return
    const payload = await response.json()
    this.element.querySelectorAll(".preset-link").forEach((button) => button.classList.toggle("active", button === event.currentTarget))
    this._buildChart(payload)
    this._renderBalanceRows(payload.balance_rows || [])
  }

  async toggleEps(event) {
    const desired = event.target.checked
    this._hideError(this.epsErrorTarget)
    try {
      const response = await fetch("/solakon/eps", {
        method: "PATCH",
        headers: this._jsonHeaders(),
        body: JSON.stringify({ enabled: desired }),
      })
      const data = await response.json()
      if (!response.ok) throw new Error(data.error || "Schalten fehlgeschlagen")
      this.epsStateTarget.textContent = data.enabled ? "An" : "Aus"
      event.target.checked = data.enabled
    } catch (error) {
      event.target.checked = !desired
      this._showError(this.epsErrorTarget, error.message)
    }
  }

  async toggleAutoRegulation(event) {
    const desired = event.target.checked
    this._hideError(this.autoRegulationErrorTarget)
    try {
      const response = await fetch("/solakon/auto_regulation", {
        method: "PATCH",
        headers: this._jsonHeaders(),
        body: JSON.stringify({ active: desired }),
      })
      const data = await response.json()
      if (!response.ok) throw new Error(data.error || "Umschalten fehlgeschlagen")
      event.target.checked = data.active
      this.autoRegulationStateTarget.textContent = data.active ? "Aktiv" : "Pausiert"
      this.autoRegulationHelpTarget.textContent = data.active ? "hält Einspeisung nahe 0 W" : "pausiert"
    } catch (error) {
      event.target.checked = !desired
      this._showError(this.autoRegulationErrorTarget, error.message)
    }
  }

  async fetchLive() {
    try {
      const response = await fetch("/api/live")
      if (!response.ok) return
      const data = await response.json()
      if (data.energy_flow) this.updateEnergyFlow(data.energy_flow)
    } catch (error) {
      console.error("solakon fetchLive failed:", error)
    }
  }

  updateEnergyFlow(flow) {
    const pvW = flow.solakon_online ? Math.max(0, flow.solar_w || 0) : null
    const homeW = flow.home_w
    const gridW = flow.grid_w
    const batteryW = flow.battery_w
    const batterySoc = flow.battery_soc_pct

    if (this.hasEfPvWTarget) this.efPvWTarget.textContent = pvW == null ? "— W" : `${pvW.toFixed(0)} W`
    if (this.hasEfConsumerWTarget) this.efConsumerWTarget.textContent = homeW == null ? "— W" : `${homeW.toFixed(0)} W`
    if (this.hasEfGridWTarget) this.efGridWTarget.textContent = gridW == null ? "— W" : gridW > 0 ? `+${gridW.toFixed(0)} W` : gridW < 0 ? `−${Math.abs(gridW).toFixed(0)} W` : "0 W"
    if (this.hasEfBatterySocTarget) this.efBatterySocTarget.textContent = batterySoc == null ? "— %" : `${batterySoc.toFixed(0)}%`
    if (this.hasEfBatteryWTarget) this.efBatteryWTarget.textContent = batteryW == null ? "— W" : batteryW > 0 ? `−${batteryW.toFixed(0)} W` : batteryW < 0 ? `${Math.abs(batteryW).toFixed(0)} W` : "0 W"

    const gridToHome = gridW > 0 ? gridW : 0
    const solarToGrid = gridW < 0 ? Math.abs(gridW) : 0
    const batteryChargeW = batteryW > 0 ? batteryW : 0
    const batteryDischargeW = batteryW < 0 ? Math.abs(batteryW) : 0
    const solarForBattery = pvW == null ? 0 : Math.max(0, pvW - solarToGrid)
    const solarToBattery = Math.min(batteryChargeW, solarForBattery)
    const gridToBattery = Math.max(0, batteryChargeW - solarToBattery)
    const batteryToHome = Math.min(batteryDischargeW, homeW || 0)
    const solarToHome = pvW == null ? 0 : Math.max(0, pvW - solarToGrid - solarToBattery)

    const paths = {
      solarHome: "M 200,122 C 205,150 250,166 306,170",
      solarGrid: "M 200,122 C 195,150 150,166 94,170",
      solarBattery: "M 200,122 L 200,218",
      gridHome: "M 94,170 L 306,170",
      gridBattery: "M 94,170 C 150,174 195,190 200,218",
      batteryHome: "M 200,218 C 205,190 250,174 306,170",
    }
    const lens = { solarHome: 123, solarGrid: 123, solarBattery: 96, gridHome: 212, gridBattery: 123, batteryHome: 123 }

    this._efSetDots("efDotsSolarHomeTarget", paths.solarHome, "#f59f00", solarToHome, lens.solarHome)
    this._efSetDots("efDotsSolarGridTarget", paths.solarGrid, "#8b5cf6", solarToGrid, lens.solarGrid)
    this._efSetDots("efDotsSolarBatteryTarget", paths.solarBattery, "#ec4899", solarToBattery, lens.solarBattery)
    this._efSetDots("efDotsGridHomeTarget", paths.gridHome, "#3b82f6", gridToHome, lens.gridHome)
    this._efSetDots("efDotsGridBatteryTarget", paths.gridBattery, "#94a3b8", gridToBattery, lens.gridBattery)
    this._efSetDots("efDotsBatteryHomeTarget", paths.batteryHome, "#14b8a6", batteryToHome, lens.batteryHome)
  }

  _readPayload() {
    try {
      return JSON.parse(this.historyPayloadTarget.textContent)
    } catch (error) {
      return { chart: { labels: [], datasets: [] }, balance_rows: [] }
    }
  }

  _buildChart(payload) {
    if (!this.hasHistoryCanvasTarget) return
    const chart = payload.chart || { labels: [], datasets: [] }
    const colors = { "PV": "#f59f00", "Akku": "#14b8a6", "Netz": "#3b82f6", "0 W": "#6c757d" }
    const datasets = (chart.datasets || []).map((dataset) => ({
      label: dataset.label,
      data: dataset.data,
      borderColor: colors[dataset.label] || "#6c757d",
      backgroundColor: dataset.label === "PV" ? "rgba(245,159,0,0.14)" : "transparent",
      borderDash: dataset.label === "0 W" ? [4, 4] : [],
      fill: dataset.label === "PV",
      pointRadius: 0,
      tension: 0.2,
    }))

    this.chart?.destroy()
    this.chart = new Chart(this.historyCanvasTarget, {
      type: "line",
      data: { labels: chart.labels || [], datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: { y: { title: { display: true, text: "Watt" } } },
        plugins: { legend: { position: "bottom", labels: { boxWidth: 12, boxHeight: 12, padding: 10, font: { size: 12 } } } },
        animation: false,
      },
    })
  }

  _renderBalanceRows(rows) {
    if (!this.hasBalanceRowsTarget) return
    this.balanceRowsTarget.innerHTML = rows.map((row) => `
      <div class="solakon-balance-row ${row.role}">
        <span class="solakon-balance-label">${row.label}</span>
        <span class="report-ranking-bar" aria-hidden="true"><span style="width: ${row.share}%"></span></span>
        <span class="report-ranking-value">${row.value}</span>
      </div>
    `).join("")
  }

  _jsonHeaders() {
    return {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content,
    }
  }

  _showError(target, message) {
    target.textContent = message
    target.hidden = false
  }

  _hideError(target) {
    target.textContent = ""
    target.hidden = true
  }

  _efDur(w, len) {
    return w < 1 ? null : Math.max(0.5, Math.min(8, len / w))
  }

  _efSetDots(targetName, path, color, w, len) {
    const target = this[targetName]
    if (!target) return
    const dur = this._efDur(w, len)
    const prev = this.efLastDur[targetName]
    const changed = dur === null ? prev != null : prev == null || Math.abs(dur - prev) / prev > 0.05
    if (!changed) return
    this.efLastDur[targetName] = dur
    target.innerHTML = ""
    if (!dur) return
    const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    for (let i = 0; i < 3; i++) {
      const c = document.createElementNS("http://www.w3.org/2000/svg", "circle")
      c.setAttribute("r", "4.5")
      c.setAttribute("fill", color)
      c.style.cssText = reduceMotion ? `offset-path:path("${path}");offset-distance:${25 + i * 25}%` : `offset-path:path("${path}")`
      target.appendChild(c)
      if (!reduceMotion) {
        c.animate([{ offsetDistance: "0%" }, { offsetDistance: "100%" }], { duration: dur * 1000, delay: -(i * dur / 3) * 1000, iterations: Infinity, easing: "linear" })
      }
    }
  }
}
```

- [ ] **Step 5: Verify controller tests still pass**

Run:

```bash
rtk bin/rails test test/controllers/solakon_controller_test.rb
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
rtk git add app/javascript/controllers/solakon_controller.js app/views/solakon/index.html.erb test/controllers/solakon_controller_test.rb
rtk git commit -m "feat: add Solakon page interactions"
```

---

## Task 11: Add Generated Plush Battery Asset Family

**Files:**
- Add/replace: `app/assets/images/solakon_battery_normal.webp`
- Add: `app/assets/images/solakon_battery_charging.webp`
- Add: `app/assets/images/solakon_battery_low.webp`
- Add: `app/assets/images/solakon_battery_hot.webp`
- Add: `app/assets/images/solakon_battery_cold.webp`
- Add: `app/assets/images/solakon_battery_fault.webp`
- Replace: `app/assets/images/nav_pv_plush.webp`
- Modify: `app/views/solakon/index.html.erb`
- Test: `test/controllers/solakon_controller_test.rb`, `test/controllers/dashboard_controller_test.rb`

**Interfaces:**
- Assets are stored in project assets, not temporary generation output folders.
- Dashboard hero uses `solakon_battery_normal.webp`.
- Solakon status section exposes image tags with state-specific assets for future live switching.

- [ ] **Step 1: Write failing asset assertions**

In `test/controllers/solakon_controller_test.rb`, add:

```ruby
test "battery character assets are wired for all states" do
  get "/solakon"

  assert_response :success
  %w[
    solakon_battery_normal
    solakon_battery_charging
    solakon_battery_low
    solakon_battery_hot
    solakon_battery_cold
    solakon_battery_fault
  ].each do |basename|
    assert_select "img[data-solakon-battery-state][src*='#{basename}']", minimum: 1
  end
end
```

- [ ] **Step 2: Generate or prepare assets**

Use the `imagegen` skill to generate a family based on:

```text
Reference: docs/superpowers/specs/2026-06-20-solakon-battery-character-reference.png.
Create six matching plush-style battery characters for a compact Rails dashboard UI.
Style: soft plush toy, friendly Ziwoas app asset style, clear white/transparent-ish background suitable for web UI, readable at 64px, no text in the image.
States:
1 normal friendly calm
2 charging active sunny energized
3 low charge sleepy tired
4 overtemperature sweating
5 cold shivering
6 fault confused distressed but not scary
```

Save final exported WebP files exactly as:

```bash
app/assets/images/solakon_battery_normal.webp
app/assets/images/solakon_battery_charging.webp
app/assets/images/solakon_battery_low.webp
app/assets/images/solakon_battery_hot.webp
app/assets/images/solakon_battery_cold.webp
app/assets/images/solakon_battery_fault.webp
app/assets/images/nav_pv_plush.webp
```

If image generation returns PNG, convert with ImageMagick if available:

```bash
rtk magick input.png -resize 512x512 -quality 88 app/assets/images/solakon_battery_normal.webp
```

Expected: each final asset exists under `app/assets/images`.

- [ ] **Step 3: Wire image family into Solakon page**

In the Solakon status or storage area, add a compact battery character strip:

```erb
<div class="solakon-battery-states" aria-hidden="true">
  <%= image_tag "solakon_battery_normal.webp", class: "solakon-battery-character is-active", data: { solakon_battery_state: "normal" }, alt: "" %>
  <%= image_tag "solakon_battery_charging.webp", class: "solakon-battery-character", data: { solakon_battery_state: "charging" }, alt: "" %>
  <%= image_tag "solakon_battery_low.webp", class: "solakon-battery-character", data: { solakon_battery_state: "low" }, alt: "" %>
  <%= image_tag "solakon_battery_hot.webp", class: "solakon-battery-character", data: { solakon_battery_state: "hot" }, alt: "" %>
  <%= image_tag "solakon_battery_cold.webp", class: "solakon-battery-character", data: { solakon_battery_state: "cold" }, alt: "" %>
  <%= image_tag "solakon_battery_fault.webp", class: "solakon-battery-character", data: { solakon_battery_state: "fault" }, alt: "" %>
</div>
```

Add CSS:

```css
.solakon-battery-states {
  display: flex;
  gap: 8px;
  align-items: center;
  overflow-x: auto;
  margin-bottom: 10px;
}
.solakon-battery-character {
  width: 52px;
  height: 52px;
  object-fit: contain;
  opacity: 0.45;
}
.solakon-battery-character.is-active {
  opacity: 1;
}
```

- [ ] **Step 4: Verify tests and assets**

Run:

```bash
rtk bin/rails test test/controllers/solakon_controller_test.rb test/controllers/dashboard_controller_test.rb
rtk ls app/assets/images/solakon_battery_*.webp app/assets/images/nav_pv_plush.webp
```

Expected: tests PASS and all seven asset files listed.

- [ ] **Step 5: Commit**

```bash
rtk git add app/assets/images/solakon_battery_*.webp app/assets/images/nav_pv_plush.webp app/views/solakon/index.html.erb app/assets/stylesheets/application.css test/controllers/solakon_controller_test.rb
rtk git commit -m "feat: add Solakon battery character assets"
```

---

## Task 12: Add Error/Unavailable UI Behavior And System Smoke

**Files:**
- Modify: `app/views/solakon/index.html.erb`
- Modify: `app/javascript/controllers/solakon_controller.js`
- Modify: `app/assets/stylesheets/application.css`
- Create: `test/system/solakon_overview_test.rb`
- Test: `test/system/solakon_overview_test.rb`, `test/controllers/solakon_controller_test.rb`

**Interfaces:**
- Page loads without fresh Solakon reading.
- Live values show placeholders.
- Controls can show concise failure messages.
- Chart is present even with no history and does not crash.

- [ ] **Step 1: Write system smoke test**

Create `test/system/solakon_overview_test.rb`:

```ruby
require_relative "application_system_test_case"

class SolakonOverviewTest < ApplicationSystemTestCase
  setup do
    SolakonReading.delete_all
    SolakonSnapshot.delete_all
  end

  test "Solakon page is usable on mobile without fresh data" do
    page.driver.browser.manage.window.resize_to(390, 844)

    visit solakon_path

    assert_text "PV"
    assert_text "Energiefluss"
    assert_text "Außensteckdose"
    assert_text "Auto-Regelung"
    assert_text "Batteriegesundheit"
    assert_selector "canvas[data-solakon-target='historyCanvas']"
    assert_no_text "SOH"
    assert_no_text "Modbus"

    chart_box = page.evaluate_script(<<~JS)
      (() => {
        const canvas = document.querySelector("canvas[data-solakon-target='historyCanvas']");
        const rect = canvas.getBoundingClientRect();
        return { width: rect.width, height: rect.height };
      })();
    JS

    assert_operator chart_box.fetch("width"), :>, 250
    assert_operator chart_box.fetch("height"), :>, 180
  end
end
```

- [ ] **Step 2: Run system test and verify failure**

Run:

```bash
rtk bin/rails test test/system/solakon_overview_test.rb
```

Expected: FAIL if Chart.js or layout targets are missing; PASS if previous tasks already covered it.

- [ ] **Step 3: Add unavailable styling and clear placeholders**

Ensure all Solakon page values use `"—"` when nil. Add this CSS:

```css
.solakon-control-card.is-unavailable,
.solakon-panel-card.is-unavailable {
  opacity: 0.68;
}
.solakon-page button.preset-link {
  background: var(--card);
  font: inherit;
  cursor: pointer;
}
.solakon-page button.preset-link.active {
  background: #fff8db;
}
```

- [ ] **Step 4: Make chart robust to empty payload**

In `app/javascript/controllers/solakon_controller.js`, ensure `_buildChart` uses an empty chart object if payload is missing:

```javascript
const chart = payload?.chart || { labels: [], datasets: [] }
```

Ensure `selectRange` catches network errors:

```javascript
try {
  const response = await fetch(`/solakon/history.json?range=${encodeURIComponent(range)}`)
  if (!response.ok) return
  const payload = await response.json()
  this.element.querySelectorAll(".preset-link").forEach((button) => button.classList.toggle("active", button === event.currentTarget))
  this._buildChart(payload)
  this._renderBalanceRows(payload.balance_rows || [])
} catch (error) {
  console.error("solakon history load failed:", error)
}
```

- [ ] **Step 5: Verify system smoke and controller tests**

Run:

```bash
rtk bin/rails test test/system/solakon_overview_test.rb test/controllers/solakon_controller_test.rb
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
rtk git add app/views/solakon/index.html.erb app/javascript/controllers/solakon_controller.js app/assets/stylesheets/application.css test/system/solakon_overview_test.rb
rtk git commit -m "test: cover Solakon overview smoke"
```

---

## Task 13: Final Verification

**Files:**
- No code files expected.

- [ ] **Step 1: Run focused Solakon test suite**

Run:

```bash
rtk bin/rails test test/solakon_client_test.rb test/models/solakon_reading_test.rb test/models/solakon_snapshot_test.rb test/models/solakon_control_state_test.rb test/models/solakon_history_test.rb test/jobs/solakon_monitor_job_test.rb test/jobs/solakon_snapshot_job_test.rb test/jobs/zero_export_tick_job_test.rb test/controllers/solakon_controller_test.rb test/controllers/solakon_controls_controller_test.rb test/controllers/dashboard_controller_test.rb test/system/solakon_overview_test.rb
```

Expected: PASS.

- [ ] **Step 2: Run full Rails test suite**

Run:

```bash
rtk bin/rails test
```

Expected: PASS.

- [ ] **Step 3: Run app lint/security checks if available**

Run:

```bash
rtk bin/rubocop
rtk bin/brakeman
```

Expected: PASS or only pre-existing unrelated warnings. If either command is unavailable or fails for an unrelated existing reason, record the exact output in the implementation handoff.

- [ ] **Step 4: Manual browser verification**

Run the dev server:

```bash
rtk bin/dev
```

Visit:

```text
http://localhost:3000/solakon
```

Verify:

- The first viewport shows the real Solakon page, not a landing page.
- Navigation includes `PV` and still fits on mobile.
- The page order is: energy flow, controls, panel cards, storage cards, graph/balance, status.
- Panel 1 and Panel 2 are visible; Panel 3 and Panel 4 are absent.
- Main UI labels say `Außensteckdose`, `Auto-Regelung`, `Batteriegesundheit`, `PV`, `Akku`, `Netz`.
- Main UI does not show `SOH`, `EPS`, register numbers, bit labels, raw alarm names, or `Ladezyklen`.
- Chart legend is `PV`, `Akku`, `Netz`, `0 W`.
- Sign explanation below chart says Akku `+` charges/`-` discharges and Netz `+` Bezug/`-` Einspeisung.
- EPS toggle reverts and shows a concise error if the device is unavailable.
- Auto-Regelung toggle is disabled and grey when `solakon.control_enabled: false`.

- [ ] **Step 5: Final commit if verification-only fixes were needed**

If Task 13 required any small fixes:

```bash
rtk git add <changed files>
rtk git commit -m "fix: polish Solakon overview verification issues"
```

If no files changed, do not create an empty commit.

---

## Self-Review Against Spec

### Spec Coverage

- Dedicated Solakon ONE page: covered by Tasks 6, 9, 10, 12.
- Single continuous page, not tabs: covered by Task 6 tests asserting no `role='tablist'` and page section order.
- Reuse dashboard live energy-flow visual pattern: covered by Task 8 shared partial and Task 10 Solakon live flow controller.
- Show only Panel 1 and Panel 2: covered by Task 3 `connected_panels` and Task 9 controller assertions.
- User-facing labels and no protocol language in main UI: covered by Tasks 6, 7, 9, 12 tests and manual verification.
- Außensteckdose direct Solakon EPS control, not PlugCommander: covered by Task 1 `set_eps_output!` and Task 7 controller tests.
- Auto-Regelung runtime pause/resume plus config master flag: covered by Task 4 model/job gate and Task 7 forbidden response.
- Storage cards and no charge-cycle claim: covered by Task 9 storage assertions.
- Chart.js combined graph with PV/Akku/Netz/0 W and range chips: covered by Tasks 5 and 10.
- Report-style balance progressbars: covered by Task 5 rows and Task 9 CSS/markup.
- Status and alarms compact with raw details hidden from main UI: covered by Task 1 decoder, Task 3 snapshot messages, Task 9 status/details.
- Plush battery assets stored in project assets: covered by Task 11.
- Fast vs slow Solakon data split: covered by Task 2 fast fields and Task 3 slow snapshots.
- Slow snapshot cadence about 10 minutes: covered by Task 3 recurring schedule.
- Solakon unavailable behavior: covered by Task 12.

### Placeholder Scan

No task uses `TBD`, `TODO`, `implement later`, or unconstrained "add appropriate" phrasing. Every code-changing task includes file paths, code snippets, commands, expected failures, expected passes, and a commit command.

### Type Consistency

- Runtime state consistently uses `SolakonControlState`, `auto_regulation_paused`, `auto_regulation_active?`, `pause_auto_regulation!`, and `resume_auto_regulation!`.
- Snapshot history consistently uses `SolakonSnapshot`, `SolakonHistory`, `battery_health_pct` for UI label `Batteriegesundheit`, and signed `grid_power_w` where positive means import.
- Solakon register access consistently uses `FIELD_SPECS`, `read_fields`, `decode_register_value`, `read_panels`, and `decode_energy_counters`; new fields should extend specs instead of duplicating `read_holding_registers` and scaling math.
- Stimulus target prefix is consistently `solakon` for Solakon page and `dashboard` for dashboard page.
- Chart dataset labels are consistently `PV`, `Akku`, `Netz`, `0 W`.

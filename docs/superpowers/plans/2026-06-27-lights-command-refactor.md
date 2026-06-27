# Lights-Command-Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Den fetten `LightSwitchesController#create`-`case`-Block durch typisierte, isoliert testbare dry-rb Command-Operations ersetzen; der Controller wird zu einem schlanken `LightsController#command`, der nur dispatcht und das Result rendert.

**Architecture:** Pro Command eine `Dry::Operation` (Railway/Result) unter `Lights::Operations::*`. Param-Coercion über `Dry::Struct` (einfache Commands) bzw. `Dry::Validation::Contract` (Zone-Commands mit `light`-Kontext), beide gebaut auf einem `Lights::Types`-Modul. Operations sind View-frei und liefern ein `Lights::Results::*`-Wertobjekt; der Controller mappt es auf Turbo-Streams. Eine Dispatch-Tabelle direkt am `Lights::Operations`-Modul (`Lights::Operations[name]`) bildet command-Name → Operation ab.

**Tech Stack:** Ruby 4.0, Rails 8.1, Minitest, dry-types/dry-struct/dry-validation/dry-operation (dry-monads kommt transitiv über dry-operation). Govee-Befehle gehen weiterhin über `Govees::Commander` (MQTT, unverändert).

## Global Constraints

- Ruby `>= 4.0`, Rails `~> 8.1.2`, Test-Framework **Minitest** (`bin/rails test`).
- Namespace **`Lights::*`** liegt unter **`app/models/lights/`** (Zeitwerk-Root `app/models`, Konvention wie `Sensors::ReadingPresenter`). Keine zusätzliche Autoload-Konfiguration.
- `lib/govees/commander.rb` (`Govees::Commander`) bleibt **unverändert** und wird über `config.autoload_lib` autogeladen — **kein** expliziter `require` nötig.
- **Endpoint bleibt POST** auf `/lights/:light_key/command`, Route-Helper-Name bleibt `light_command`. Views (`button_to … light_command_path`) bleiben unverändert.
- Wert-Constraints exakt aus den UI-Slidern: **Brightness `1..100`**, **Kelvin `2700..6500`**, **RgbComponent `0..255`**.
- Die bestehende Integrationstest-Suite (heute `test/controllers/light_switches_controller_test.rb`) ist das **Regressions-Sicherheitsnetz** und muss vor und nach dem Umbau grün sein — Verhalten ändert sich 1:1 nicht.
- Style: `rubocop-rails-omakase` (`bin/rubocop`) muss grün bleiben.
- Failure-Konvention der Operations: `Failure([:invalid, detail])` für Param-/Kontextfehler, `Failure([:commander, error])` für `Govees::Commander::Error`.

---

### Task 1: dry-rb Gems hinzufügen

**Files:**
- Modify: `Gemfile`
- Modify: `Gemfile.lock` (durch `bundle install`)

**Interfaces:**
- Produces: Lädt `Dry::Operation`, `Dry::Validation::Contract`, `Dry::Struct`, `Dry::Types`, `Dry::Monads::Result::Success`/`Failure` ins Projekt.

- [ ] **Step 1: Gems im Gemfile ergänzen**

Direkt nach der bestehenden `gem "turbo-rails"`/Asset-Block-Gruppe (oder ans Ende der Haupt-Gem-Liste, vor der `group :development`-Sektion) einfügen:

```ruby
# Typisierte, komponierbare Command-Operations für den Lights-Endpoint
gem "dry-types"
gem "dry-struct"
gem "dry-validation"
gem "dry-operation"
```

- [ ] **Step 2: Installieren**

Run: `bundle install`
Expected: Auflösung erfolgreich; neu u.a. `dry-struct`, `dry-validation`, `dry-operation`, `dry-monads`, `dry-matcher`. `dry-types`/`dry-schema`/`dry-core` bleiben auf den bereits gelockten Versionen (1.9.1 / 1.16.0 / 1.2.0).

- [ ] **Step 3: Laden verifizieren**

Run: `bin/rails runner 'p [Dry::Operation, Dry::Validation::Contract, Dry::Struct, Dry::Types, Dry::Monads::Result::Success, Dry::Monads::Result::Failure]'`
Expected: Gibt die sechs Konstanten ohne Fehler aus.

- [ ] **Step 4: Audit grün halten**

Run: `bin/bundler-audit`
Expected: `No vulnerabilities found` (oder unverändert zur Ausgangslage).

- [ ] **Step 5: Commit**

```bash
git add Gemfile Gemfile.lock
git commit -m "chore(lights): add dry-operation/validation/struct/types deps"
```

---

### Task 2: `Lights::Types` + `Lights::Params`

**Files:**
- Create: `app/models/lights/types.rb`
- Create: `app/models/lights/params.rb`
- Test: `test/models/lights/types_test.rb`
- Test: `test/models/lights/params_test.rb`

**Interfaces:**
- Consumes: dry-types/dry-struct aus Task 1.
- Produces:
  - `Lights::Types::Bool` (Params-Coercion `"true"/"false" → bool`)
  - `Lights::Types::Brightness` (Integer, `1..100`)
  - `Lights::Types::Kelvin` (Integer, `2700..6500`)
  - `Lights::Types::RgbComponent` (Integer, `0..255`)
  - `Lights::Types::SceneName` (non-empty String)
  - `Lights::Params::Turn(on:)`, `Params::Brightness(value:)`, `Params::Color(r:, g:, b:)`, `Params::ColorTemp(kelvin:)`, `Params::Scene(scene:)` — `Dry::Struct`, koerzieren beim `.new`, werfen `Dry::Struct::Error` bei ungültig.

- [ ] **Step 1: Failing test für Types schreiben**

```ruby
# test/models/lights/types_test.rb
require "test_helper"

class Lights::TypesTest < ActiveSupport::TestCase
  test "Bool coerces form strings" do
    assert_equal true,  Lights::Types::Bool["true"]
    assert_equal false, Lights::Types::Bool["false"]
  end

  test "Brightness coerces and enforces 1..100" do
    assert_equal 42, Lights::Types::Brightness["42"]
    assert_raises(Dry::Types::ConstraintError) { Lights::Types::Brightness["0"] }
    assert_raises(Dry::Types::ConstraintError) { Lights::Types::Brightness["101"] }
  end

  test "Kelvin enforces the slider range" do
    assert_equal 2700, Lights::Types::Kelvin["2700"]
    assert_equal 6500, Lights::Types::Kelvin["6500"]
    assert_raises(Dry::Types::ConstraintError) { Lights::Types::Kelvin["2000"] }
  end

  test "RgbComponent enforces 0..255" do
    assert_equal 255, Lights::Types::RgbComponent["255"]
    assert_raises(Dry::Types::ConstraintError) { Lights::Types::RgbComponent["256"] }
  end
end
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `bin/rails test test/models/lights/types_test.rb`
Expected: FAIL — `uninitialized constant Lights::Types`.

- [ ] **Step 3: Types implementieren**

```ruby
# app/models/lights/types.rb
module Lights
  module Types
    include Dry.Types()

    Bool         = Params::Bool
    Brightness   = Params::Integer.constrained(gteq: 1, lteq: 100)
    Kelvin       = Params::Integer.constrained(gteq: 2700, lteq: 6500)
    RgbComponent = Params::Integer.constrained(gteq: 0, lteq: 255)
    SceneName    = Params::String.constrained(min_size: 1)
  end
end
```

- [ ] **Step 4: Types-Test laufen lassen, grün bestätigen**

Run: `bin/rails test test/models/lights/types_test.rb`
Expected: PASS (4 runs).

- [ ] **Step 5: Failing test für Params schreiben**

```ruby
# test/models/lights/params_test.rb
require "test_helper"

class Lights::ParamsTest < ActiveSupport::TestCase
  test "Turn coerces the on flag" do
    assert_equal true,  Lights::Params::Turn.new(on: "true").on
    assert_equal false, Lights::Params::Turn.new(on: "false").on
  end

  test "Brightness wraps out-of-range in Dry::Struct::Error" do
    assert_equal 42, Lights::Params::Brightness.new(value: "42").value
    assert_raises(Dry::Struct::Error) { Lights::Params::Brightness.new(value: "0") }
  end

  test "Color coerces three components" do
    c = Lights::Params::Color.new(r: "10", g: "20", b: "30")
    assert_equal [ 10, 20, 30 ], [ c.r, c.g, c.b ]
  end

  test "ColorTemp coerces kelvin" do
    assert_equal 4000, Lights::Params::ColorTemp.new(kelvin: "4000").kelvin
  end

  test "Scene rejects a blank name" do
    assert_equal "Forest", Lights::Params::Scene.new(scene: "Forest").scene
    assert_raises(Dry::Struct::Error) { Lights::Params::Scene.new(scene: "") }
  end
end
```

- [ ] **Step 6: Test laufen lassen, Fehlschlag bestätigen**

Run: `bin/rails test test/models/lights/params_test.rb`
Expected: FAIL — `uninitialized constant Lights::Params`.

- [ ] **Step 7: Params implementieren**

```ruby
# app/models/lights/params.rb
module Lights
  module Params
    class Turn < Dry::Struct
      attribute :on, Types::Bool
    end

    class Brightness < Dry::Struct
      attribute :value, Types::Brightness
    end

    class Color < Dry::Struct
      attribute :r, Types::RgbComponent
      attribute :g, Types::RgbComponent
      attribute :b, Types::RgbComponent
    end

    class ColorTemp < Dry::Struct
      attribute :kelvin, Types::Kelvin
    end

    class Scene < Dry::Struct
      attribute :scene, Types::SceneName
    end
  end
end
```

- [ ] **Step 8: Params-Test laufen lassen, grün bestätigen**

Run: `bin/rails test test/models/lights/params_test.rb`
Expected: PASS (5 runs).

- [ ] **Step 9: Commit**

```bash
git add app/models/lights/types.rb app/models/lights/params.rb test/models/lights/types_test.rb test/models/lights/params_test.rb
git commit -m "feat(lights): add dry-types domain types and command param structs"
```

---

### Task 3: `Lights::Contracts` (Zone, ZoneUndo)

**Files:**
- Create: `app/models/lights/contracts/zone.rb`
- Create: `app/models/lights/contracts/zone_undo.rb`
- Test: `test/models/lights/contracts_test.rb`

**Interfaces:**
- Consumes: nichts aus den vorigen Tasks (eigenständig).
- Produces:
  - `Lights::Contracts::Zone.new(light:).call(zone:, on:)` → `Dry::Validation::Result`; bei Erfolg `result.to_h == { zone: String, on: Bool }`.
  - `Lights::Contracts::ZoneUndo.new(light:).call(victim:, added:)` → `Result`; bei Erfolg `{ victim:, added: }`.
  - Beide failen, wenn ein Zone-Key nicht in `light.zones` liegt. `on` wird von `"true"/"false"` zu bool koerziert (Params-Schema).

- [ ] **Step 1: Failing test schreiben**

```ruby
# test/models/lights/contracts_test.rb
require "test_helper"

class Lights::ContractsTest < ActiveSupport::TestCase
  setup do
    @light = Light.new(name: "Up", key: "X", zones: %w[rippleLightToggle sideLightToggle])
  end

  test "Zone passes for a known zone and coerces on" do
    r = Lights::Contracts::Zone.new(light: @light).call(zone: "rippleLightToggle", on: "true")
    assert r.success?
    assert_equal({ zone: "rippleLightToggle", on: true }, r.to_h)
  end

  test "Zone fails for a zone not on this light" do
    r = Lights::Contracts::Zone.new(light: @light).call(zone: "powerSwitch", on: "true")
    assert r.failure?
  end

  test "ZoneUndo requires both zones on the light" do
    ok = Lights::Contracts::ZoneUndo.new(light: @light).call(victim: "rippleLightToggle", added: "sideLightToggle")
    assert ok.success?
    bad = Lights::Contracts::ZoneUndo.new(light: @light).call(victim: "rippleLightToggle", added: "nope")
    assert bad.failure?
  end
end
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `bin/rails test test/models/lights/contracts_test.rb`
Expected: FAIL — `uninitialized constant Lights::Contracts`.

- [ ] **Step 3: Contracts implementieren**

```ruby
# app/models/lights/contracts/zone.rb
module Lights
  module Contracts
    class Zone < Dry::Validation::Contract
      option :light

      params do
        required(:zone).filled(:string)
        required(:on).filled(:bool)
      end

      rule(:zone) do
        key.failure("is not a zone of this light") unless light.zones.include?(value)
      end
    end
  end
end
```

```ruby
# app/models/lights/contracts/zone_undo.rb
module Lights
  module Contracts
    class ZoneUndo < Dry::Validation::Contract
      option :light

      params do
        required(:victim).filled(:string)
        required(:added).filled(:string)
      end

      rule(:victim) do
        key.failure("is not a zone of this light") unless light.zones.include?(value)
      end

      rule(:added) do
        key.failure("is not a zone of this light") unless light.zones.include?(value)
      end
    end
  end
end
```

- [ ] **Step 4: Test laufen lassen, grün bestätigen**

Run: `bin/rails test test/models/lights/contracts_test.rb`
Expected: PASS (3 runs).

- [ ] **Step 5: Commit**

```bash
git add app/models/lights/contracts test/models/lights/contracts_test.rb
git commit -m "feat(lights): add dry-validation contracts for zone commands"
```

---

### Task 4: `Lights::Results` Wertobjekte

**Files:**
- Create: `app/models/lights/results.rb`
- Test: `test/models/lights/results_test.rb`

**Interfaces:**
- Produces:
  - `Lights::Results::Power.new(light:)` mit Reader `#light`.
  - `Lights::Results::Zones.new(light:, zone_keys:, toast:)` mit Readern `#light`, `#zone_keys`, `#toast`. `toast` ist `nil` (kein Toast), `{ evicted:, added: }` (Toast zeigen) oder `:clear` (Toast leeren).
  - `Lights::Results::NoContent.new` (leeres Marker-Objekt).

- [ ] **Step 1: Failing test schreiben**

```ruby
# test/models/lights/results_test.rb
require "test_helper"

class Lights::ResultsTest < ActiveSupport::TestCase
  test "Power carries the light" do
    light = Light.new(key: "A")
    assert_same light, Lights::Results::Power.new(light: light).light
  end

  test "Zones carries keys and toast payload" do
    r = Lights::Results::Zones.new(light: Light.new(key: "A"),
                                   zone_keys: %w[sideLightToggle rippleLightToggle],
                                   toast: { evicted: "rippleLightToggle", added: "sideLightToggle" })
    assert_equal %w[sideLightToggle rippleLightToggle], r.zone_keys
    assert_equal({ evicted: "rippleLightToggle", added: "sideLightToggle" }, r.toast)
  end

  test "NoContent constructs" do
    assert_instance_of Lights::Results::NoContent, Lights::Results::NoContent.new
  end
end
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `bin/rails test test/models/lights/results_test.rb`
Expected: FAIL — `uninitialized constant Lights::Results`.

- [ ] **Step 3: Results implementieren**

```ruby
# app/models/lights/results.rb
module Lights
  module Results
    Power     = Struct.new(:light, keyword_init: true)
    Zones     = Struct.new(:light, :zone_keys, :toast, keyword_init: true)
    NoContent = Class.new
  end
end
```

- [ ] **Step 4: Test laufen lassen, grün bestätigen**

Run: `bin/rails test test/models/lights/results_test.rb`
Expected: PASS (3 runs).

- [ ] **Step 5: Commit**

```bash
git add app/models/lights/results.rb test/models/lights/results_test.rb
git commit -m "feat(lights): add command result value objects"
```

---

### Task 5: `Lights::Operations::Base` + einfache Operations

**Files:**
- Create: `app/models/lights/operations/base.rb`
- Create: `app/models/lights/operations/turn.rb`
- Create: `app/models/lights/operations/set_brightness.rb`
- Create: `app/models/lights/operations/set_color.rb`
- Create: `app/models/lights/operations/set_color_temp.rb`
- Create: `app/models/lights/operations/set_scene.rb`
- Test: `test/models/lights/operations/turn_test.rb`
- Test: `test/models/lights/operations/simple_operations_test.rb`

**Interfaces:**
- Consumes: `Lights::Params::*` (Task 2), `Lights::Results::*` (Task 4), `Govees::Commander`.
- Produces:
  - `Lights::Operations::Base` — Mixin: inkludiert `Dry::Operation`; private Helfer `coerce { … }` (rescue `Dry::Struct::Error` → `Failure([:invalid, e])`), `validate(result)` (dry-validation-Result → `Success(values)`/`Failure([:invalid, errors])`), `via_commander { … }` (rescue `Govees::Commander::Error` → `Failure([:commander, e])`).
  - `Lights::Operations::Turn#call(light:, params:, mqtt_config:)` → `Success(Results::Power)`; routet zone-Lampen über `set_zone(powerSwitch)`, sonst `turn`; schreibt `LightState.record_state(on:)`.
  - `SetBrightness`/`SetColor`/`SetColorTemp`/`SetScene#call(light:, params:, mqtt_config:)` → `Success(Results::NoContent)`.

- [ ] **Step 1: Failing test für Turn schreiben**

```ruby
# test/models/lights/operations/turn_test.rb
require "test_helper"

class Lights::Operations::TurnTest < ActiveSupport::TestCase
  setup { @cfg = Object.new }

  test "simple lamp calls Commander.turn, persists state, returns Power" do
    light = Light.create!(name: "L", key: "S1", zones: [])
    calls = []
    Govees::Commander.stub(:turn, ->(l, on:, mqtt_config:) { calls << [ l.key, on ] }) do
      result = Lights::Operations::Turn.new.call(light: light, params: { on: "true" }, mqtt_config: @cfg)
      assert result.success?
      assert_instance_of Lights::Results::Power, result.value!
    end
    assert_equal [ [ "S1", true ] ], calls
    assert_equal true, LightState.find_by(light_key: "S1").on
  end

  test "zone lamp routes power through powerSwitch" do
    light = Light.create!(name: "U", key: "U1", zones: %w[bottomLightToggle sideLightToggle])
    seen = {}
    Govees::Commander.stub(:set_zone, ->(l, zone:, on:, mqtt_config:) { seen[:zone] = zone; seen[:on] = on }) do
      Lights::Operations::Turn.new.call(light: light, params: { on: "true" }, mqtt_config: @cfg)
    end
    assert_equal "powerSwitch", seen[:zone]
    assert_equal true, seen[:on]
  end

  test "broker failure returns a commander failure" do
    light = Light.create!(name: "L", key: "S2", zones: [])
    boom = ->(*, **) { raise Govees::Commander::Error, "down" }
    Govees::Commander.stub(:turn, boom) do
      result = Lights::Operations::Turn.new.call(light: light, params: { on: "true" }, mqtt_config: @cfg)
      assert result.failure?
      assert_equal :commander, result.failure.first
    end
  end

  test "uncoercible flag returns an invalid failure" do
    light = Light.create!(name: "L", key: "S3", zones: [])
    result = Lights::Operations::Turn.new.call(light: light, params: { on: "" }, mqtt_config: @cfg)
    assert result.failure?
    assert_equal :invalid, result.failure.first
  end
end
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `bin/rails test test/models/lights/operations/turn_test.rb`
Expected: FAIL — `uninitialized constant Lights::Operations::Turn`.

- [ ] **Step 3: Base-Mixin implementieren**

```ruby
# app/models/lights/operations/base.rb
module Lights
  module Operations
    module Base
      def self.included(base)
        base.include(Dry::Operation)
      end

      private

      # Build a typed struct from raw params; coercion/structure failures => :invalid.
      def coerce
        Success(yield)
      rescue Dry::Struct::Error => e
        Failure([ :invalid, e ])
      end

      # Turn a dry-validation result into a monad of its coerced values.
      def validate(result)
        return Failure([ :invalid, result.errors ]) if result.failure?

        Success(result.to_h)
      end

      # Run a Commander side effect; broker errors => :commander.
      def via_commander
        yield
        Success()
      rescue Govees::Commander::Error => e
        Failure([ :commander, e ])
      end
    end
  end
end
```

- [ ] **Step 4: Turn implementieren**

```ruby
# app/models/lights/operations/turn.rb
module Lights
  module Operations
    class Turn
      include Base

      def call(light:, params:, mqtt_config:)
        attrs = step coerce { Params::Turn.new(on: params[:on]) }

        step via_commander {
          if light.zone_lamp?
            Govees::Commander.set_zone(light, zone: "powerSwitch", on: attrs.on, mqtt_config: mqtt_config)
          else
            Govees::Commander.turn(light, on: attrs.on, mqtt_config: mqtt_config)
          end
        }

        LightState.record_state(light.key, on: attrs.on)
        Success(Results::Power.new(light: light))
      end
    end
  end
end
```

- [ ] **Step 5: Turn-Test laufen lassen, grün bestätigen**

Run: `bin/rails test test/models/lights/operations/turn_test.rb`
Expected: PASS (4 runs).

- [ ] **Step 6: Failing test für die übrigen einfachen Operations schreiben**

```ruby
# test/models/lights/operations/simple_operations_test.rb
require "test_helper"

class Lights::Operations::SimpleOperationsTest < ActiveSupport::TestCase
  setup do
    @cfg   = Object.new
    @light = Light.create!(name: "L", key: "C1", zones: [])
  end

  test "SetBrightness forwards the coerced value and returns NoContent" do
    seen = nil
    Govees::Commander.stub(:set_brightness, ->(l, value:, mqtt_config:) { seen = value }) do
      result = Lights::Operations::SetBrightness.new.call(light: @light, params: { value: "42" }, mqtt_config: @cfg)
      assert result.success?
      assert_instance_of Lights::Results::NoContent, result.value!
    end
    assert_equal 42, seen
  end

  test "SetBrightness rejects an out-of-range value" do
    result = Lights::Operations::SetBrightness.new.call(light: @light, params: { value: "0" }, mqtt_config: @cfg)
    assert result.failure?
    assert_equal :invalid, result.failure.first
  end

  test "SetColor forwards three components" do
    seen = {}
    Govees::Commander.stub(:set_color, ->(l, r:, g:, b:, mqtt_config:) { seen = { r:, g:, b: } }) do
      result = Lights::Operations::SetColor.new.call(light: @light, params: { r: "10", g: "20", b: "30" }, mqtt_config: @cfg)
      assert result.success?
    end
    assert_equal({ r: 10, g: 20, b: 30 }, seen)
  end

  test "SetColorTemp forwards kelvin from the temp_k param" do
    seen = nil
    Govees::Commander.stub(:set_color_temp, ->(l, kelvin:, mqtt_config:) { seen = kelvin }) do
      Lights::Operations::SetColorTemp.new.call(light: @light, params: { temp_k: "4000" }, mqtt_config: @cfg)
    end
    assert_equal 4000, seen
  end

  test "SetScene accepts the effect param" do
    seen = nil
    Govees::Commander.stub(:set_scene, ->(l, scene:, mqtt_config:) { seen = scene }) do
      Lights::Operations::SetScene.new.call(light: @light, params: { effect: "Forest" }, mqtt_config: @cfg)
    end
    assert_equal "Forest", seen
  end

  test "SetScene also accepts the scene param" do
    seen = nil
    Govees::Commander.stub(:set_scene, ->(l, scene:, mqtt_config:) { seen = scene }) do
      Lights::Operations::SetScene.new.call(light: @light, params: { scene: "Ocean" }, mqtt_config: @cfg)
    end
    assert_equal "Ocean", seen
  end

  test "broker failure surfaces as a commander failure" do
    boom = ->(*, **) { raise Govees::Commander::Error, "down" }
    Govees::Commander.stub(:set_brightness, boom) do
      result = Lights::Operations::SetBrightness.new.call(light: @light, params: { value: "42" }, mqtt_config: @cfg)
      assert result.failure?
      assert_equal :commander, result.failure.first
    end
  end
end
```

- [ ] **Step 7: Test laufen lassen, Fehlschlag bestätigen**

Run: `bin/rails test test/models/lights/operations/simple_operations_test.rb`
Expected: FAIL — `uninitialized constant Lights::Operations::SetBrightness`.

- [ ] **Step 8: Die vier einfachen Operations implementieren**

```ruby
# app/models/lights/operations/set_brightness.rb
module Lights
  module Operations
    class SetBrightness
      include Base

      def call(light:, params:, mqtt_config:)
        attrs = step coerce { Params::Brightness.new(value: params[:value]) }
        step via_commander { Govees::Commander.set_brightness(light, value: attrs.value, mqtt_config: mqtt_config) }
        Success(Results::NoContent.new)
      end
    end
  end
end
```

```ruby
# app/models/lights/operations/set_color.rb
module Lights
  module Operations
    class SetColor
      include Base

      def call(light:, params:, mqtt_config:)
        attrs = step coerce { Params::Color.new(r: params[:r], g: params[:g], b: params[:b]) }
        step via_commander { Govees::Commander.set_color(light, r: attrs.r, g: attrs.g, b: attrs.b, mqtt_config: mqtt_config) }
        Success(Results::NoContent.new)
      end
    end
  end
end
```

```ruby
# app/models/lights/operations/set_color_temp.rb
module Lights
  module Operations
    class SetColorTemp
      include Base

      def call(light:, params:, mqtt_config:)
        attrs = step coerce { Params::ColorTemp.new(kelvin: params[:temp_k]) }
        step via_commander { Govees::Commander.set_color_temp(light, kelvin: attrs.kelvin, mqtt_config: mqtt_config) }
        Success(Results::NoContent.new)
      end
    end
  end
end
```

```ruby
# app/models/lights/operations/set_scene.rb
module Lights
  module Operations
    class SetScene
      include Base

      def call(light:, params:, mqtt_config:)
        attrs = step coerce { Params::Scene.new(scene: params[:effect] || params[:scene]) }
        step via_commander { Govees::Commander.set_scene(light, scene: attrs.scene, mqtt_config: mqtt_config) }
        Success(Results::NoContent.new)
      end
    end
  end
end
```

- [ ] **Step 9: Tests laufen lassen, grün bestätigen**

Run: `bin/rails test test/models/lights/operations/simple_operations_test.rb test/models/lights/operations/turn_test.rb`
Expected: PASS (11 runs).

- [ ] **Step 10: Commit**

```bash
git add app/models/lights/operations test/models/lights/operations
git commit -m "feat(lights): add base mixin and simple command operations"
```

---

### Task 6: Zone-Operations (`SetZone` mit Eviction, `UndoZone`)

**Files:**
- Create: `app/models/lights/operations/set_zone.rb`
- Create: `app/models/lights/operations/undo_zone.rb`
- Test: `test/models/lights/operations/zone_operations_test.rb`

**Interfaces:**
- Consumes: `Lights::Operations::Base`, `Lights::Contracts::Zone`/`ZoneUndo`, `Lights::Results::Zones`, `Light::ZONE_META`, `Light#max_active_zones`, `LightState`.
- Produces:
  - `Lights::Operations::SetZone#call(light:, params:, mqtt_config:)` → `Success(Results::Zones)`. Bei einer eingeschalteten Seiten-Zone über dem Limit wird eine andere eingeschaltete Seiten-Zone evicted (aus); `zone_keys` enthält dann `[zone, evicted]`, `toast` ist `{ evicted:, added: zone }`. Ohne Eviction: `zone_keys == [zone]`, `toast == nil`.
  - `Lights::Operations::UndoZone#call(light:, params:, mqtt_config:)` → `Success(Results::Zones)` mit `zone_keys == [victim, added]`, `toast == :clear`.

- [ ] **Step 1: Failing test schreiben**

```ruby
# test/models/lights/operations/zone_operations_test.rb
require "test_helper"

class Lights::Operations::ZoneOperationsTest < ActiveSupport::TestCase
  setup { @cfg = Object.new }

  test "SetZone toggles a valid zone and returns it without a toast" do
    light = Light.create!(name: "U", key: "Z0", zones: %w[bottomLightToggle rippleLightToggle])
    calls = []
    Govees::Commander.stub(:set_zone, ->(l, zone:, on:, mqtt_config:) { calls << [ zone, on ] }) do
      result = Lights::Operations::SetZone.new.call(light: light, params: { zone: "rippleLightToggle", on: "true" }, mqtt_config: @cfg)
      assert result.success?
      r = result.value!
      assert_equal [ "rippleLightToggle" ], r.zone_keys
      assert_nil r.toast
    end
    assert_equal [ [ "rippleLightToggle", true ] ], calls
    assert_equal true, LightState.find_by(light_key: "Z0").zone_states["rippleLightToggle"]
  end

  test "SetZone rejects a zone not on this light" do
    light = Light.create!(name: "U", key: "Z2", zones: %w[bottomLightToggle])
    result = Lights::Operations::SetZone.new.call(light: light, params: { zone: "powerSwitch", on: "true" }, mqtt_config: @cfg)
    assert result.failure?
    assert_equal :invalid, result.failure.first
  end

  test "SetZone evicts an on side when over the limit and emits a toast" do
    light = Light.create!(name: "U", key: "Z1", sku: "H60B0",
                          zones: %w[bottomLightToggle rippleLightToggle sideLightToggle])
    LightState.record_zone_state("Z1", "bottomLightToggle", true) # main on
    LightState.record_zone_state("Z1", "rippleLightToggle", true) # one side on -> at limit (2)
    calls = []
    Govees::Commander.stub(:set_zone, ->(l, zone:, on:, mqtt_config:) { calls << [ zone, on ] }) do
      result = Lights::Operations::SetZone.new.call(light: light, params: { zone: "sideLightToggle", on: "true" }, mqtt_config: @cfg)
      assert result.success?
      r = result.value!
      assert_equal [ "sideLightToggle", "rippleLightToggle" ], r.zone_keys
      assert_equal({ evicted: "rippleLightToggle", added: "sideLightToggle" }, r.toast)
    end
    state = LightState.find_by(light_key: "Z1")
    assert_equal false, state.zone_states["rippleLightToggle"]
    assert_equal true,  state.zone_states["sideLightToggle"]
    assert_equal true,  state.zone_states["bottomLightToggle"]
    assert_includes calls, [ "rippleLightToggle", false ]
    assert_includes calls, [ "sideLightToggle", true ]
  end

  test "UndoZone restores victim, turns off added, clears the toast" do
    light = Light.create!(name: "U", key: "Z3", zones: %w[rippleLightToggle sideLightToggle])
    LightState.record_zone_state("Z3", "sideLightToggle", true)
    calls = []
    Govees::Commander.stub(:set_zone, ->(l, zone:, on:, mqtt_config:) { calls << [ zone, on ] }) do
      result = Lights::Operations::UndoZone.new.call(light: light, params: { victim: "rippleLightToggle", added: "sideLightToggle" }, mqtt_config: @cfg)
      assert result.success?
      r = result.value!
      assert_equal [ "rippleLightToggle", "sideLightToggle" ], r.zone_keys
      assert_equal :clear, r.toast
    end
    state = LightState.find_by(light_key: "Z3")
    assert_equal true,  state.zone_states["rippleLightToggle"]
    assert_equal false, state.zone_states["sideLightToggle"]
    assert_includes calls, [ "rippleLightToggle", true ]
    assert_includes calls, [ "sideLightToggle", false ]
  end
end
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `bin/rails test test/models/lights/operations/zone_operations_test.rb`
Expected: FAIL — `uninitialized constant Lights::Operations::SetZone`.

- [ ] **Step 3: SetZone implementieren**

```ruby
# app/models/lights/operations/set_zone.rb
module Lights
  module Operations
    class SetZone
      include Base

      def call(light:, params:, mqtt_config:)
        attrs = step validate(Contracts::Zone.new(light: light).call(zone: params[:zone], on: params[:on]))
        zone = attrs[:zone]
        on   = attrs[:on]

        evicted = on ? evict_for(light, zone) : nil
        if evicted
          LightState.record_zone_state(light.key, evicted, false)
          step via_commander { Govees::Commander.set_zone(light, zone: evicted, on: false, mqtt_config: mqtt_config) }
        end

        LightState.record_zone_state(light.key, zone, on)
        step via_commander { Govees::Commander.set_zone(light, zone: zone, on: on, mqtt_config: mqtt_config) }

        toast = evicted ? { evicted: evicted, added: zone } : nil
        Success(Results::Zones.new(light: light, zone_keys: [ zone, evicted ].compact, toast: toast))
      end

      private

      # Which currently-on side zone must turn off so this side can come on.
      def evict_for(light, zone)
        return nil unless Light::ZONE_META.dig(zone, :role) == "side"

        max = light.max_active_zones.to_i
        return nil unless max.positive?

        bits = LightState.find_by(light_key: light.key)&.zone_states || {}
        on_zones = light.zones.select { |z| bits[z] } - [ zone ]
        return nil if on_zones.size < max

        on_zones.find { |z| Light::ZONE_META.dig(z, :role) == "side" }
      end
    end
  end
end
```

- [ ] **Step 4: UndoZone implementieren**

```ruby
# app/models/lights/operations/undo_zone.rb
module Lights
  module Operations
    class UndoZone
      include Base

      def call(light:, params:, mqtt_config:)
        attrs = step validate(Contracts::ZoneUndo.new(light: light).call(victim: params[:victim], added: params[:added]))
        victim = attrs[:victim]
        added  = attrs[:added]

        LightState.record_zone_state(light.key, victim, true)
        step via_commander { Govees::Commander.set_zone(light, zone: victim, on: true, mqtt_config: mqtt_config) }

        LightState.record_zone_state(light.key, added, false)
        step via_commander { Govees::Commander.set_zone(light, zone: added, on: false, mqtt_config: mqtt_config) }

        Success(Results::Zones.new(light: light, zone_keys: [ victim, added ], toast: :clear))
      end
    end
  end
end
```

- [ ] **Step 5: Test laufen lassen, grün bestätigen**

Run: `bin/rails test test/models/lights/operations/zone_operations_test.rb`
Expected: PASS (4 runs).

- [ ] **Step 6: Commit**

```bash
git add app/models/lights/operations/set_zone.rb app/models/lights/operations/undo_zone.rb test/models/lights/operations/zone_operations_test.rb
git commit -m "feat(lights): add zone set/undo operations with eviction"
```

---

### Task 7: Dispatch-Tabelle am `Lights::Operations`-Modul

Statt einer separaten `Lights::Registry` lebt die command-Name → Operation-Tabelle
direkt am `Lights::Operations`-Modul. Dazu wird der bisher *implizite* Zeitwerk-Namespace
(aus dem Verzeichnis `operations/`) zu einem *expliziten*: die Datei
`app/models/lights/operations.rb` definiert das Modul samt Tabelle, die Kind-Dateien
`operations/*.rb` bleiben unverändert und werden bei Bedarf autogeladen.

**Files:**
- Create: `app/models/lights/operations.rb`
- Test: `test/models/lights/operations_test.rb`

**Interfaces:**
- Consumes: alle `Lights::Operations::*`-Klassen (Tasks 5–6).
- Produces: `Lights::Operations[name]` → Operation-Klasse oder `nil`. Keys: `turn`, `zone`, `brightness`, `color`, `color_temp`, `effect`, `scene`, `zone_undo` (`effect` und `scene` mappen beide auf `SetScene`).

- [ ] **Step 1: Failing test schreiben**

```ruby
# test/models/lights/operations_test.rb
require "test_helper"

class Lights::OperationsTest < ActiveSupport::TestCase
  test "maps command names to operation classes" do
    assert_equal Lights::Operations::Turn,          Lights::Operations["turn"]
    assert_equal Lights::Operations::SetZone,       Lights::Operations["zone"]
    assert_equal Lights::Operations::SetBrightness, Lights::Operations["brightness"]
    assert_equal Lights::Operations::SetColor,      Lights::Operations["color"]
    assert_equal Lights::Operations::SetColorTemp,  Lights::Operations["color_temp"]
    assert_equal Lights::Operations::SetScene,      Lights::Operations["effect"]
    assert_equal Lights::Operations::SetScene,      Lights::Operations["scene"]
    assert_equal Lights::Operations::UndoZone,      Lights::Operations["zone_undo"]
  end

  test "returns nil for an unknown command" do
    assert_nil Lights::Operations["explode"]
  end
end
```

- [ ] **Step 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `bin/rails test test/models/lights/operations_test.rb`
Expected: FAIL — `undefined method '[]' for module Lights::Operations` (der implizite Namespace hat noch keine `[]`-Methode).

- [ ] **Step 3: Explizite Namespace-Datei mit Dispatch-Tabelle anlegen**

```ruby
# app/models/lights/operations.rb
module Lights
  module Operations
    # command name (param) -> operation class
    ALL = {
      "turn"       => Turn,
      "zone"       => SetZone,
      "brightness" => SetBrightness,
      "color"      => SetColor,
      "color_temp" => SetColorTemp,
      "effect"     => SetScene,
      "scene"      => SetScene,
      "zone_undo"  => UndoZone
    }.freeze

    def self.[](name) = ALL[name]
  end
end
```

- [ ] **Step 4: Test laufen lassen, grün bestätigen**

Run: `bin/rails test test/models/lights/operations_test.rb`
Expected: PASS (2 runs).

- [ ] **Step 5: Commit**

```bash
git add app/models/lights/operations.rb test/models/lights/operations_test.rb
git commit -m "feat(lights): add command dispatch table on the operations module"
```

---

### Task 8: Controller verschlanken + Route umhängen + alten Controller entfernen

Dies ist der Verdrahtungs-Task. Das **Sicherheitsnetz** ist die bestehende
Integrationstest-Suite — sie wird NICHT umgeschrieben (nur am Ende umbenannt) und
muss grün bleiben, was beweist, dass sich das Verhalten 1:1 nicht ändert.

**Files:**
- Modify: `config/routes.rb:22-24`
- Modify: `app/controllers/lights_controller.rb`
- Delete: `app/controllers/light_switches_controller.rb`
- Modify (umbenennen): `test/controllers/light_switches_controller_test.rb` → `test/controllers/lights_command_test.rb`

**Interfaces:**
- Consumes: `Lights::Operations[]`, `Lights::Results::*`, `LightRow`, `Light::ZONE_META`, `app_config.mqtt`.
- Produces: `POST /lights/:light_key/command` → `LightsController#command`. Antworten unverändert: Turbo-Streams (Power-Dual-Target / Zonen + Toast) bzw. `head :no_content`; `404` (unbekannte Lampe), `422` (unbekannter Command / ungültige Params), `503` (Broker-Fehler).

- [ ] **Step 1: Bestehende Suite gegen den ALTEN Controller laufen lassen (Baseline grün)**

Run: `bin/rails test test/controllers/light_switches_controller_test.rb`
Expected: PASS (alle Tests grün — das ist die Baseline, die nach dem Umbau identisch grün bleiben muss).

- [ ] **Step 2: `command` + Render-Helfer in `LightsController` ergänzen**

In `app/controllers/lights_controller.rb` die `command`-Action (öffentlich, vor `private`) und die Render-Helfer (nach `private`, neben den bestehenden) ergänzen. Bestehende Actions/`set_light`/`light_params` bleiben unverändert.

```ruby
  # öffentlich, z.B. direkt nach `def index = ...`
  def command
    light = Light.find_by(key: params[:light_key])
    return head :not_found unless light

    operation = Lights::Operations[params[:command]]
    return head :unprocessable_entity unless operation

    result = operation.new.call(light: light, params: params, mqtt_config: app_config.mqtt)
    return render_result(light, result.value!) if result.success?

    failure = result.failure
    if failure.is_a?(Array) && failure.first == :commander
      head :service_unavailable
    else
      head :unprocessable_entity
    end
  end
```

```ruby
  # nach `private`, zusätzlich zu set_light / light_params:

  def render_result(light, result)
    case result
    when Lights::Results::Power     then respond_power(light)
    when Lights::Results::Zones     then respond_zones(light, result.zone_keys, result.toast)
    when Lights::Results::NoContent then head :no_content
    end
  end

  # Render both targets: the detail page hero (#light_power) and the /switches
  # list card (#light_card_<key>). Turbo applies only the action whose target
  # exists in the current DOM, so one endpoint serves both pages without JS.
  def respond_power(light)
    row = LightRow.new(light: light, state: LightState.find_by(light_key: light.key))
    render turbo_stream: [
      turbo_stream.replace("light_power", partial: "lights/power", locals: { light: light, row: row }),
      turbo_stream.replace("light_card_#{light.key}", partial: "switches/light_card", locals: { row: row })
    ]
  end

  def respond_zones(light, zone_keys, toast)
    zones = LightRow.new(light: light, state: LightState.find_by(light_key: light.key)).zones.index_by(&:key)
    streams = zone_keys.map { |k|
      turbo_stream.replace("zone_#{k}", partial: "lights/zone", locals: { zone: zones[k], light_key: light.key })
    }
    streams << toast_stream(light, toast) if toast
    render turbo_stream: streams
  end

  def toast_stream(light, toast)
    message, undo =
      if toast == :clear
        [ nil, nil ]
      else
        label = Light::ZONE_META.dig(toast[:evicted], :label)
        [ "#{label} ausgeschaltet · max. #{light.max_active_zones} Zonen",
          { light_key: light.key, victim: toast[:evicted], added: toast[:added] } ]
      end
    turbo_stream.replace("light_toast", partial: "lights/toast", locals: { message: message, undo: undo })
  end
```

- [ ] **Step 3: Route umhängen**

In `config/routes.rb` den `scope "/lights/:light_key"`-Block ändern (Verb POST und Helper-Name `light_command` bleiben):

```ruby
  scope "/lights/:light_key" do
    post "command", to: "lights#command", as: :light_command
  end
```

- [ ] **Step 4: Alten Controller löschen**

```bash
git rm app/controllers/light_switches_controller.rb
```

- [ ] **Step 5: Bestehende Suite gegen den NEUEN Controller laufen lassen (muss identisch grün sein)**

Run: `bin/rails test test/controllers/light_switches_controller_test.rb`
Expected: PASS — exakt dieselben Tests grün wie in Step 1. Schlägt einer fehl, ist das Verhalten abgewichen → vor dem Weitermachen fixen (kein Test anpassen, sondern die Operation/den Controller).

- [ ] **Step 6: Test-Datei umbenennen (Klarheit; Verhalten unverändert)**

```bash
git mv test/controllers/light_switches_controller_test.rb test/controllers/lights_command_test.rb
```

In `test/controllers/lights_command_test.rb` Klassennamen und Kommentar anpassen:

```ruby
# test/controllers/lights_command_test.rb
require "test_helper"

class LightsCommandTest < ActionDispatch::IntegrationTest
```

(Restlicher Inhalt der Datei bleibt unverändert.)

- [ ] **Step 7: Umbenannte Suite laufen lassen**

Run: `bin/rails test test/controllers/lights_command_test.rb`
Expected: PASS (16 runs — wie zuvor).

- [ ] **Step 8: Vollständige Test-Suite + Style**

Run: `bin/rails test`
Expected: PASS (gesamte Suite grün).

Run: `bin/rubocop`
Expected: keine Offenses.

- [ ] **Step 9: Commit**

```bash
git add app/controllers/lights_controller.rb config/routes.rb test/controllers/lights_command_test.rb
git commit -m "refactor(lights): slim controller to dispatch dry-rb command operations

Replace the fat LightSwitchesController#create case block with
LightsController#command dispatching Lights::Registry operations; the old
controller is removed and the endpoint stays POST /lights/:key/command."
```

---

## Self-Review

**Spec coverage:**
- Typ-Schicht (`Lights::Types`) → Task 2. ✔ (Bool, Brightness 1..100, Kelvin 2700..6500, RgbComponent 0..255, SceneName)
- Param-Strukturen (`Dry::Struct`) → Task 2 (`Lights::Params::*`). ✔ Ersetzen die im Spec genannten Param-Structs; `dry-struct` deckt die einfachen Commands ab.
- Contracts (`dry-validation`) → Task 3 (Zone, ZoneUndo). ✔ `BrightnessContract` aus dem Spec entfällt bewusst — der Range sitzt auf Typ-Ebene (`Lights::Types::Brightness`), wie der Spec bereits andeutete („großteils schon auf Typ-Ebene").
- Operations (`dry-operation`) + Dispatch-Tabelle → Tasks 5–7. ✔ (Tabelle sitzt direkt am `Lights::Operations`-Modul via expliziter Namespace-Datei, statt einer separaten `Lights::Registry`)
- Result-Wertobjekte → Task 4. ✔ (Power, Zones, NoContent; Toast-Copy im Controller, Result trägt nur Daten)
- Schlanker Controller, Pattern-Match-Mapping → Task 8. ✔ (statt Pattern-Matching auf dry-monads-Konstanten bewusst robustes `success?`/`failure?` + `case/when` auf Result-Klassen — versionssicher)
- Routing: ein Command-Endpoint → Task 8. ✔ **Abweichung vom Spec:** POST statt PATCH (hält Views + Test-Sicherheitsnetz unverändert, konsistent mit `plug_switches`). Spec-Routing-Abschnitt entsprechend angepasst.
- Tests (Operations/Contracts/Types/Controller) → in jedem Task. ✔
- Phase 2 (Commander-Payloads/`ZONE_META` typisieren) → bewusst NICHT in diesem Plan (eigener späterer Spec/Plan).

**Placeholder scan:** Keine TBD/TODO/„später"-Stellen; jeder Code-Step enthält vollständigen Code, jeder Test-Step echten Test-Code.

**Type consistency:** `Lights::Types::*`, `Lights::Params::*`, `Lights::Contracts::{Zone,ZoneUndo}`, `Lights::Results::{Power,Zones,NoContent}`, `Lights::Operations::{Base,Turn,SetBrightness,SetColor,SetColorTemp,SetScene,SetZone,UndoZone}` plus `Lights::Operations[]` (Dispatch) — Namen durchgängig identisch über alle Tasks. Failure-Tags `:invalid`/`:commander` einheitlich. `Results::Zones#toast` ∈ `{nil, {evicted:, added:}, :clear}` konsistent zwischen Task 4, 6 und 8.

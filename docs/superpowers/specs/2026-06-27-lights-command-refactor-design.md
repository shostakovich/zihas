# Lights-Command-Refactor — dry-rb Command-Operations

**Datum:** 2026-06-27
**Branch:** `feature/govee-lights`
**Status:** Design freigegeben, Plan ausstehend

## Problem

`LightSwitchesController#create` ist ein fettes `case`-Statement, das vier
Verantwortlichkeiten vermischt:

1. **Command-Dispatch** (`case params[:command]` über turn/zone/brightness/color/color_temp/effect/scene/zone_undo)
2. **Param-Coercion** (`to_i`, `cast_bool`)
3. **Domänen-Seiteneffekte** (`Govees::Commander` publish + `LightState` schreiben), inkl. Zonen-Eviction und Undo
4. **Turbo-Stream-Response-Shaping** (Dual-Target bei `turn`, Zonen + Toast bei `zone`, `head :no_content` sonst)

Die eigentliche Komplexität liegt nicht im Dispatch, sondern in der Domänenlogik
(Zonen-Eviction, Undo, Toast, Dual-Target-Responses). Die Action ist dadurch schwer
zu lesen, schwer isoliert zu testen und wächst mit jedem neuen Command.

## Ziel

- Logik aus der Action in typisierte, isoliert testbare Command-Operations ziehen.
- Volle dry-rb-Strenge: `dry-operation` (Railway/Result) + `dry-types`/`dry-struct`
  (Typmodellierung) + `dry-validation` (Param- und Kontextvalidierung).
- Einen Command-Endpoint behalten (`PATCH /lights/:key/command`), Dispatch über eine
  Registry. `LightSwitchesController` entfällt.
- Operations sind **View-frei** und liefern ein typisiertes Result; der Controller
  mappt Result → Turbo-Streams.

## Nicht-Ziel / YAGNI

- Kein RESTful-Aufsplitten in Sub-Resources (`/power`, `/zones`, …). Ein
  Command-Endpoint bleibt.
- `lib/govees/commander.rb` bleibt unverändert (web-seitiger Choke-Point zum Bridge).
- Vollständige Typisierung der Commander-MQTT-Payloads ist eigene Phase 2 (siehe unten),
  nicht Teil des ersten Schritts.

## Architektur

### 1. Typ-Schicht — `Lights::Types`

Ein `Dry.Types()`-Modul mit den Domänen-Typen, die heute als lose Strings/Ints durch
den Controller laufen:

| Typ | Definition |
|---|---|
| `Bool` | String/Int → bool (ersetzt `cast_bool`) |
| `Brightness` | Integer, constrained `0..100` |
| `Kelvin` | Integer, constrained (Bereich beim Plan festnageln, z.B. `2000..9000`) |
| `RgbComponent` | Integer, constrained `0..255` |
| `ZoneRole` | Enum `"main" \| "side"` (für `Light::ZONE_META`) |
| `CommandName` | Enum der Registry-Keys |

Plus `Dry::Struct`-Param-Objekte pro Command:

- `TurnParams(on:)`
- `ZoneParams(zone:, on:)`
- `BrightnessParams(value:)`
- `ColorParams(r:, g:, b:)`
- `ColorTempParams(kelvin:)`
- `SceneParams(scene:)`
- `ZoneUndoParams(victim:, added:)`

### 2. Validierungs-Schicht — Contracts (`dry-validation`)

Ein Contract pro Command, der die rohen Params validiert **und** koerziert, plus
kontextuelle Regeln, die das `light` brauchen (via `option :light`):

- `ZoneContract`: `zone` ∈ `light.zones`
- `ZoneUndoContract`: `victim` & `added` ∈ `light.zones`
- `BrightnessContract`: `value` 0..100 (großteils schon auf Typ-Ebene)

Der Contract liefert ein `dry-validation`-Result, das in der Operation per `.to_monad`
zu `Success(attrs)` / `Failure(errors)` wird.

### 3. Operations — `dry-operation` + Registry

Eine Operation-Klasse je Command, alle View-frei. Schema:

```ruby
class Lights::SetBrightness
  include Dry::Operation

  def call(light:, params:, mqtt_config:)
    attrs = step validate(params, light)
    step publish(light, attrs, mqtt_config)
    Success(Results::NoContent.new)
  end

  private

  def validate(params, light) = BrightnessContract.new.call(params, light:).to_monad

  def publish(light, attrs, cfg)
    Govees::Commander.set_brightness(light, value: attrs[:value], mqtt_config: cfg)
    Success()
  rescue Govees::Commander::Error => e
    Failure([:commander, e])
  end
end
```

- `Lights::Turn` schreibt zusätzlich `LightState.record_state`, behandelt `zone_lamp?`
  (powerSwitch vs. turn) und liefert `Results::Power`.
- `Lights::SetZone` kapselt die komplette **Eviction**-Logik (heute `evict_for`):
  ermittelt das zu verdrängende Zone, schreibt beide `record_zone_state`, publisht beide
  `set_zone` und gibt im Result `evicted:` zurück.
- `Lights::UndoZone` macht die Eviction rückgängig (victim an, added aus).
- `Lights::SetColor`, `SetColorTemp`, `SetScene` → `Results::NoContent`.

Dispatch über einen Registry-Hash:

```ruby
Lights::REGISTRY = {
  "turn"       => Lights::Turn,
  "zone"       => Lights::SetZone,
  "brightness" => Lights::SetBrightness,
  "color"      => Lights::SetColor,
  "color_temp" => Lights::SetColorTemp,
  "effect"     => Lights::SetScene,
  "scene"      => Lights::SetScene,
  "zone_undo"  => Lights::UndoZone
}.freeze
```

### 4. Result-Wertobjekte — `Lights::Results`

Typisierte Results, an denen der Controller das Rendering festmacht:

- `Results::Power.new(light:)` → Dual-Target-Render (`#light_power` + `#light_card_<key>`)
- `Results::Zones.new(light:, zone_keys:, evicted:, added:)` → Zonen-Render + optional Toast
- `Results::NoContent` → `head :no_content`

Die **Toast-Copy** (`"<Label> ausgeschaltet · max. N Zonen"`) ist User-Text, keine
Domäne → sie wandert in den Renderer/Partial. Das Result trägt nur die Daten
(`evicted`, `added`, ggf. `max`), nicht den fertigen String.

### 5. Controller — `LightsController#command`

Schlank, dispatcht und mappt Result → Response per Pattern-Match:

```ruby
class LightsController < ApplicationController
  def command
    light = Light.find_by(key: params[:light_key]) or return head :not_found
    op = Lights::REGISTRY[params[:command]] or return head :unprocessable_entity

    case op.new.call(light:, params:, mqtt_config: app_config.mqtt)
    in Success(result)          then render_result(light, result)
    in Failure([:commander, _]) then head :service_unavailable
    in Failure(_)               then head :unprocessable_entity
    end
  end

  private

  def render_result(light, result)
    case result
    in Results::Power            then respond_power(light)
    in Results::Zones => r       then respond_zone(light, r)
    in Results::NoContent        then head :no_content
    end
  end
end
```

`respond_power` / `respond_zone` (die bestehende Turbo-Stream-Glue inkl. `LightRow`-
Aufbau und Partial-Auswahl) bleiben im Controller — reine View-Logik gehört dahin.

### Routing

- Neu: `PATCH /lights/:light_key/command → lights#command` (as: `:light_command`).
- Alt entfällt: `post "command", to: "light_switches#create"`.
- Die Views nutzen schon `light_command_path(light_key:)` mit `params[:command]` —
  Helper-Name bleibt, nur HTTP-Methode/Target ändern sich. `button_to` mit
  `method: :patch` prüfen.

## Datenfluss

```
button_to (View)
  → PATCH /lights/:key/command  { command:, ...params }
    → LightsController#command
       → Lights::REGISTRY[command].new.call(light:, params:, mqtt_config:)
          → Contract.call(params, light:).to_monad      # validate + coerce
          → Govees::Commander.<verb>(...)               # MQTT publish
          → LightState.record_*                          # optimistic state
          → Success(Results::*)
       → render_result → Turbo-Streams | head :no_content
    Failure([:commander, _]) → 503
    Failure(_)               → 422
```

## Fehlerbehandlung

| Fall | Ergebnis |
|---|---|
| Light nicht gefunden | `head :not_found` |
| Unbekannter Command | `head :unprocessable_entity` |
| Param-/Kontext-Validierung schlägt fehl | `Failure(errors)` → `head :unprocessable_entity` |
| `Govees::Commander::Error` | `Failure([:commander, e])` → `head :service_unavailable` |
| Erfolg | Turbo-Streams oder `head :no_content` |

## Tests

- **Operations** (Unit): isoliert ohne Rails-View. `Commander` über `mqtt_factory`
  gestubbt, `LightState` real (DB). Pflichtpfade: Turn (Lampe vs. zone_lamp), SetZone
  mit/ohne Eviction, UndoZone, Commander-Error → Failure.
- **Contracts** (Unit): valide/invalide Params, Kontextregeln (`zone ∈ light.zones`).
- **Types** (Unit): Coercion + Constraints (Brightness 0..100, RgbComponent 0..255, Bool).
- **Controller** (Request-Spec): die drei Response-Formen (Power-Dual-Target,
  Zonen+Toast, no_content), 404/422/503.

## Verzeichnis / Namespace

Namespace `Lights::*`. Zeitwerk-Autoload-Root beim Plan festnageln (z.B. alles unter
`app/models/lights/` für `Lights::…`, oder ein neuer `app/`-Subdir als Root). Grobe
Aufteilung:

```
lights/
  types.rb              # Lights::Types
  contracts/            # ZoneContract, ZoneUndoContract, BrightnessContract, ...
  operations …          # Turn, SetZone, SetBrightness, SetColor, SetColorTemp, SetScene, UndoZone
  results.rb            # Results::Power | Zones | NoContent
  registry.rb           # Lights::REGISTRY
```

## Phasen

1. **Phase 1 (dieser Spec):** Typen + Contracts + Operations + Results + Registry +
   schlanker `LightsController#command`, `LightSwitchesController` entfernen, Routing
   umstellen, Tests. Verhalten bleibt 1:1 identisch (Refactor, kein Feature).
2. **Phase 2 (separat):** Commander-MQTT-Payloads (`{"power"=>…}`, `{"zone"=>{…}}`,
   `{"color"=>{…}}`) und `Light::ZONE_META`-Einträge als Typen modellieren. Erst nach
   Phase 1, sonst wird der Schritt zu groß.

## Abhängigkeiten

Neue direkte Gems (heute nur transitiv im Lock vorhanden):
`dry-operation`, `dry-validation`, `dry-types`/`dry-struct`. Versionen beim Plan an die
gelockten dry-core/dry-types-Versionen anpassen.

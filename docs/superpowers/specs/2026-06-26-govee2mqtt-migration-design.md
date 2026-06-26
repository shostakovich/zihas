# govee2mqtt-Migration – Design

**Datum:** 2026-06-26
**Branch:** `feature/govee-lights` (noch nicht live)
**Supersedes:** Transport-/Bridge-Teile von [2026-06-24-govee-lights-design.md](2026-06-24-govee-lights-design.md)

## Ziel

Den selbstgebauten Govee-LAN-/Bridge-Stack durch den `wez/govee2mqtt`-Dienst
ersetzen. govee2mqtt übernimmt **alle** Lampen-I/O (LAN-Multicast + Govee-Cloud);
ZiWoAS wird reiner MQTT-Client seiner HA-JSON-Topics. Zusätzlich: **Auto-Discovery**
der Lampen (keine manuelle Pflege mehr). Cloud-Effekte/Szenen bleiben **out of scope**.

## Verifizierter govee2mqtt-Vertrag (aus Source `wez/govee2mqtt@main`)

- **Command-Topic:** `gv2mqtt/light/{id}/command`
- **State-Topic:** `gv2mqtt/light/{id}/state`
- `{id}` = `topic_safe_id` = MAC **ohne** `:`, Groß-/Kleinschreibung erhalten (z. B. `14ABDB4844064B60`)
- **Schema:** Home-Assistant JSON-Light (`schema: "json"`)
  - State: `{"state":"ON"|"OFF","brightness":0-100,"color":{...},"color_temp":<mired>,"color_mode":...,"effect":<scene>}`
  - `brightness_scale: 100` → keine Umrechnung (unsere 0–100 passen 1:1)
  - `color_temp` in **Mired** → `mired = 1_000_000 / kelvin` und zurück
  - `effect`/`effect_list` sind vorhanden, werden aber (noch) nicht genutzt
- **Discovery:** retained Config unter `{prefix}/light/{unique_id}/config`
  - `prefix` = `--hass-discovery-prefix` (CLI-Flag, **kein** Env-Binding), Default `homeassistant`
  - **Wir setzen den Prefix auf `ziwoas`** (selbsterklärend, kollisionsfrei falls je ein echtes HA am selben Broker hängt)
  - Config-Payload liefert: `name`, `unique_id`, `command_topic`, `state_topic`,
    `supported_color_modes`, `effect_list`, `min_mireds`/`max_mireds`, `device.identifiers`
- **Deploy:** Image `ghcr.io/wez/govee2mqtt:latest`, **`network_mode: host` erforderlich**
  (LAN-Multicast), Konfiguration via Env (`GOVEE_EMAIL/PASSWORD/API_KEY`,
  `GOVEE_MQTT_HOST/PORT`, optional `GOVEE_MQTT_USER/PASSWORD`,
  `GOVEE_TEMPERATURE_SCALE=C`), persistentes `/data`-Volume.
- **Lokaler Build:** Standard-Rust/Cargo-Projekt (`name = "govee"`, edition 2021,
  `Cargo.lock` vorhanden, sqlite `bundled`) → `cargo build --release` erzeugt das
  native Binary `govee`. Kein Docker zum Ausführen nötig.

## Architektur

**Vorher:** `Web → GoveeCommander → MQTT(govee/<slug>/…) → GoveeMqttBridge → UDP → Lampe`
und zurück über UDP → Bridge → `govee/<slug>/status` → GoveeStatusHandler.
ZiWoAS besitzt das LAN-Protokoll.

**Nachher:** govee2mqtt besitzt das Lampen-I/O. ZiWoAS spricht nur noch dessen Topics:

```
Web → GoveeCommander → MQTT(gv2mqtt/light/{MAC}/command, HA-JSON) → govee2mqtt → Lampe
Lampe → govee2mqtt → MQTT(gv2mqtt/light/{MAC}/state) → GoveeStatusHandler → LightState → ActionCable
govee2mqtt → MQTT(ziwoas/light/{uid}/config, retained) → GoveeDiscoveryHandler → Light (upsert)
```

`MqttRouter` und das Web-UI bleiben strukturell unverändert.

## Komponenten

### Identity & Schema (Migrationen direkt umbauen – Branch nicht live)

- `Light.key` **wird die MAC** (z. B. `14ABDB4844064B60`); dient als
  `LightState.light_key` und in URLs (`to_param`).
- `scene_entries` referenzieren bereits `light_id` (Integer-FK) → Szenen/Presets
  brauchen **keine** Änderung.
- **`ip_address`-Spalte + Presence-Validation entfernen** (govee2mqtt besitzt das LAN).
- `key`-Format-Validation auf Hex/Case lockern (z. B. `/\A[0-9A-Za-z]+\z/`).
- `slugify`/`assign_key` entfernen – der Key kommt aus der Discovery, nicht aus dem Namen.
- `name`, `room_id` bleiben benutzer-editierbar; `sku`, `supports_color`,
  `supports_color_temp` werden aus dem Discovery-Payload gefüllt.
- Migrationen: bestehende Lights-Migration `down` → `ip_address` entfernen → `up`.

### GoveeCommander (dünner HA-JSON-Publisher)

Gleiche Methodenoberfläche (`turn`/`set_brightness`/`set_color`/`set_color_temp`),
aber jede publiziert **ein** Teil-JSON nach `gv2mqtt/light/#{light.key}/command`:

| Methode | Payload |
|---|---|
| `turn(on:)` | `{"state":"ON"}` / `{"state":"OFF"}` |
| `set_brightness(value:)` | `{"brightness": 0-100}` |
| `set_color(r:,g:,b:)` | `{"color":{"r":,"g":,"b":}}` |
| `set_color_temp(kelvin:)` | `{"color_temp": <mired>}` (`mired = 1_000_000 / kelvin`) |

- `topic_prefix`-Parameter entfällt; gv2mqtt-Base ist Konstante.
- `refresh` entfällt (govee2mqtt published State proaktiv).

### GoveeStatusHandler (State)

- Subscription: `gv2mqtt/light/+/state`.
- Parst HA-JSON: `state`→`on`, `brightness`, `color`→`color_r/g/b`,
  `color_temp` (Mired→Kelvin), `color_mode`.
- Schreibt `LightState` per MAC (`light_key`), broadcastet auf `dashboard`.
- **Reachability:** `reachable=true` + `last_seen_at` bei State-Empfang. Das globale
  Availability-/LWT-Topic von govee2mqtt markiert bei Bridge-Ausfall alle Lampen
  als nicht erreichbar.

### GoveeDiscoveryHandler (neu, Single-Purpose)

- Subscription: `ziwoas/light/+/config` (retained).
- Konstante `DISCOVERY_PREFIX = "ziwoas"` (muss mit dem Launch-Flag übereinstimmen).
- Parst die Config-JSON, **upsert `Light` per MAC**:
  - `key` = MAC, `sku`, `supports_color`/`supports_color_temp` aus `supported_color_modes`.
  - `name` **nur beim Anlegen** setzen – Benutzer-Edits nie überschreiben.
  - **Nie löschen.** Verschwundene Lampen bleiben (werden über State/Availability
    als unreachable geführt).

### Collector-Wiring (`bin/ziwoas_collector`)

- `GoveeStatusHandler` und `GoveeDiscoveryHandler` **bedingungslos** registrieren
  (die `if config.govee`-Guard entfällt mit der Config-Sektion). Liegt govee2mqtt
  brach, kommen schlicht keine Nachrichten.

### Config

- **`govee:`-Sektion in `ziwoas.yml` und `build_govee`/`GoveeCfg` komplett entfernen.**
  gv2mqtt-/Discovery-Topics sind govee2mqtt-Konventionen → Ruby-Konstanten.
- `Config`-Struct: `:govee`-Feld entfernen.

### Web-/Model-Trim

- `LightsController`: **discovery-only** – `new`/`create` und `test_connection`
  entfernen. `edit`/`update` (umbenennen, Raum zuweisen) und `destroy`
  (manuelles Entfernen) bleiben. „Lampe hinzufügen“-Formular entfällt.
- `GoveeCommander.refresh` und der `govee_prefix`-Helper entfallen.

## Deployment

### Dev (foreman)

- govee2mqtt **lokal kompilieren** (Checkout + `cargo build --release`, auf eine
  bekannte Tag/Commit gepinnt) und das native `govee`-Binary direkt als
  `govee:`-Prozess in `Procfile.dev` laufen lassen — **kein Docker**:
  ```
  govee: <pfad>/govee --hass-discovery-prefix ziwoas serve   # + Env aus config/govee2mqtt.env
  ```
- Die alte `govee: ./bin/govee_bridge`-Zeile entfällt.
- Genaue CLI-Subcommand-/Arg-Reihenfolge im Plan gegen `govee --help` verifizieren.

### Prod (docker-compose.yml)

- Neuer Service `govee2mqtt`: `image: ghcr.io/wez/govee2mqtt:latest`,
  `network_mode: host`, `env_file: config/govee2mqtt.env`, persistentes
  `/data`-Volume, `restart: unless-stopped`, Discovery-Prefix `ziwoas` via `command:`.

### Credentials

- **Gitignored** `config/govee2mqtt.env`: `GOVEE_EMAIL/PASSWORD/API_KEY`,
  `GOVEE_MQTT_HOST/PORT`, `GOVEE_TEMPERATURE_SCALE=C`, `TZ`.
- Committed `config/govee2mqtt.env.example` dokumentiert die Variablen.

### Cleanup

- **Löschen:** `lib/govee_lan_client.rb`, `lib/govee_mqtt_bridge.rb`,
  `bin/govee_bridge` + zugehörige Specs.
- **Kamal entfernen** (ungenutzt): `config/deploy.yml`, `bin/kamal`, `.kamal/`,
  `kamal`-Gem aus dem Gemfile.

## Testing

- `GoveeCommander`: Payload-Formen + Mired-Konvertierung.
- `GoveeStatusHandler`: Parsing (Mired→K, ON/OFF, color_mode), Reachability.
- `GoveeDiscoveryHandler`: Upsert (create vs. Benutzer-Edits erhalten),
  Capability-Mapping aus `supported_color_modes`, Never-Delete.
- Collector registriert beide Handler.
- Keine Live-Lampen-Tests.

## Out of Scope (Follow-up)

- Cloud-**Effekte/Szenen** im UI. `effect_list` kommt frei in der Discovery, das
  Verdrahten in `Scene`/`Preset` ist eigene Arbeit.

## Offene Detailpunkte für die Plan-Phase

1. Exakte govee2mqtt-CLI (Subcommand `serve`? Arg-Reihenfolge) gegen `--help` prüfen.
2. Genaues Availability-/LWT-Topic + Payload („online“/„offline“) bestätigen.
3. HA-JSON: Sendet `set_brightness` ohne `state` implizit ON? Ggf. `state` mitsenden.
4. Pinning-Strategie für den lokalen govee2mqtt-Build (Tag vs. Commit).

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
- `{id}` = `topic_safe_id` = Govee-Device-ID (MAC-ähnlich, **8 Byte / 16 Hex**, z. B.
  `14ABDB4844064B60`), `:` entfernt. **Achtung:** `topic_safe_id` normalisiert die
  Schreibweise **nicht** — Case ist so, wie Govee sie liefert (geräteabhängig, manche
  Geräte lowercase ohne `:`). → ZiWoAS speichert die ID **verbatim** (genau wie
  govee2mqtt sie liefert) als `Light.key` und verwendet sie **unverändert** in
  Command/State-Topics. **Keine** Case-Transformation: die ID ist pro Gerät
  deterministisch (reine Funktion der `device.id`), also über Discovery/State/Command
  hinweg konsistent — ein Upcasen würde das Command-Topic gegen govee2mqtt brechen.
- **Schema:** Home-Assistant JSON-Light (`schema: "json"`)
  - State: `{"state":"ON"|"OFF","brightness":0-100,"color":{...},"color_temp":<mired>,"color_mode":...,"effect":<scene>}`
  - `brightness_scale: 100` → keine Umrechnung (unsere 0–100 passen 1:1)
  - `color_temp` in **Mired** → `mired = 1_000_000 / kelvin` und zurück
  - `effect`/`effect_list` sind vorhanden, werden aber (noch) nicht genutzt
- **Discovery:** retained Config unter `{prefix}/light/{unique_id}/config`
  - `prefix` = `--hass-discovery-prefix` (CLI-Flag, **kein** Env-Binding), Default `homeassistant`
  - **Wir setzen den Prefix auf `gv2mqtt`**, damit *alle* govee2mqtt-Topics unter einem
    Namespace liegen (`gv2mqtt/*`). Der Command/State-Base `gv2mqtt` ist im Source
    hartcodiert (kein Flag) → das ist der nicht-konfigurierbare Teil, also richten wir
    die Discovery danach aus.
  - `unique_id` = `gv2mqtt-{MAC}` (HA-Konvention, MAC mit Vendor-Präfix). Der Discovery-
    Topic-Knoten ist also `gv2mqtt-{MAC}`, **nicht** die nackte MAC — daher MAC **nicht**
    aus dem Topic-Pfad ableiten.
  - Config-Payload liefert: `name`, `unique_id` (`gv2mqtt-{MAC}`), `command_topic` und
    `state_topic` (beide mit **nackter** MAC), `supported_color_modes`, `effect_list`,
    `min_mireds`/`max_mireds`, `device.identifiers` (`gv2mqtt-{MAC}`).
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
govee2mqtt → MQTT(gv2mqtt/light/{uid}/config, retained) → GoveeDiscoveryHandler → Light (upsert)
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
| `set_brightness(value:)` | `{"state":"ON","brightness": 0-100}` |
| `set_color(r:,g:,b:)` | `{"state":"ON","color":{"r":,"g":,"b":}}` |
| `set_color_temp(kelvin:)` | `{"state":"ON","color_temp": <mired>}` (`mired = 1_000_000 / kelvin`) |

- **`state` ist Pflicht in jedem Command.** Das `state`-Feld im `HassLightCommand` ist
  nicht-optional → ein Payload **ohne** `state` wird von govee2mqtt **verworfen**
  (Deserialisierung schlägt fehl). Außerdem schaltet ein reines `{"brightness":N}` eine
  Lampe **nicht** an. Darum trägt jedes Teilkommando `"state":"ON"` (außer Ausschalten).
- `topic_prefix`-Parameter entfällt; gv2mqtt-Base ist Konstante.
- `refresh` entfällt (govee2mqtt published State proaktiv).

### GoveeStatusHandler (State)

- Subscription: `gv2mqtt/light/+/state`.
- Parst HA-JSON: `state`→`on`, `brightness`, `color`→`color_r/g/b`,
  `color_temp` (Mired→Kelvin), `color_mode`.
- **State ist mode-abhängig:** RGB-Mode → `color` + `color_mode:"rgb"`; Color-Temp-Mode
  → `color_temp` + `color_mode:"color_temp"` (**nie beides**); OFF ist nur
  `{"state":"OFF"}`. Handler muss fehlende Felder tolerieren (nicht überschreiben, wenn nicht vorhanden).
- Schreibt `LightState` per MAC (`light_key`), broadcastet auf `dashboard`.
- **Reachability:** `reachable=true` + `last_seen_at` bei State-Empfang. Das globale
  Availability-/LWT-Topic von govee2mqtt markiert bei Bridge-Ausfall alle Lampen
  als nicht erreichbar.

### GoveeDiscoveryHandler (neu, Single-Purpose)

- Subscription: `gv2mqtt/light/+/config` (retained).
- Konstante `DISCOVERY_PREFIX = "gv2mqtt"` (muss mit dem Launch-Flag übereinstimmen).
- **MAC-Quelle:** aus `command_topic`/`state_topic` des Payloads parsen
  (`gv2mqtt/light/{MAC}/state` → nackte MAC), **nicht** aus dem Topic-Pfad (der trägt
  `gv2mqtt-{MAC}`). Das `unique_id`/`uid` ist für uns Ballast und wird ignoriert.
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
  govee: <pfad>/govee --hass-discovery-prefix gv2mqtt serve   # + Env aus config/govee2mqtt.env
  ```
- Die alte `govee: ./bin/govee_bridge`-Zeile entfällt.
- Genaue CLI-Subcommand-/Arg-Reihenfolge im Plan gegen `govee --help` verifizieren.

### Prod (docker-compose.yml)

- Neuer Service `govee2mqtt`: `image: ghcr.io/wez/govee2mqtt:latest`,
  `network_mode: host`, `env_file: config/govee2mqtt.env`, persistentes
  `/data`-Volume, `restart: unless-stopped`, Discovery-Prefix `gv2mqtt` via `command:`.

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

## Gegen den govee2mqtt-Source validiert (2026-06-26)

Alle Vertragsaussagen oben sind gegen `wez/govee2mqtt@main` per Subagent geprüft.
Bestätigt; folgende Punkte wurden dabei korrigiert/präzisiert und sind oben eingearbeitet:

- **Command braucht `state`** (Pflichtfeld, sonst Deserialisierungs-Fehler; brightness allein schaltet nicht an).
- **Device-ID-Case** geräteabhängig → **verbatim** speichern/verwenden (nie transformieren);
  pro Gerät deterministisch und end-to-end konsistent, daher kein Normalisieren nötig.
- **State mode-abhängig** (color XOR color_temp).
- **CLI:** Subcommand `serve`, `--hass-discovery-prefix` ist `global` →
  `govee --hass-discovery-prefix gv2mqtt serve` (Flag vor oder nach `serve` ok).
- **Availability/LWT:** `gv2mqtt/availability`, `online`/`offline`, als MQTT-Last-Will — bestätigt.

### Verbleibende offene Punkte für die Plan-Phase

1. Pinning-Strategie für den lokalen govee2mqtt-Build (Tag vs. Commit).
2. govee2mqtt bindet zusätzlich einen HTTP-Port (`--http-port`, Default **8056**) — bei
   `network_mode: host` auf Port-Konflikt achten / ggf. umstellen.

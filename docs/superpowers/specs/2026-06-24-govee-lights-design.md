# Govee-Lampen (LAN) — Design

**Datum:** 2026-06-24
**Status:** Entwurf zur Freigabe
**Branch / Worktree:** `feature/govee-lights` (`.worktrees/govee-lights`, von `origin/main`)

## Konzept

Govee-Lampen (Floor Lamp 2, Wall Sconces, Uplighter Floor Lamp, perspektivisch
Deckenlampen) sollen unter `/switches` steuerbar werden: **an/aus, Helligkeit,
Farbe (RGB + Farbtemperatur)** sowie **lokal definierte Szenen**. Lampen werden
**über die UI** angelegt und verwaltet.

Gesteuert wird ausschließlich über die **Govee LAN-API** (lokales UDP, kein
Cloud-Account, kein API-Key, kein Internet). Die gesamte UDP-Hässlichkeit wird in
einer **`GoveeMqttBridge`** gekapselt — der Rest des Systems (Web-App, Collector)
kennt nur MQTT, exakt wie die Shellys nativ MQTT sprechen. Symmetrisch zur
bestehenden `FritzMqttBridge`.

### Netzwerk-Topologie (Voraussetzung)

- Lampen hängen im IoT-VLAN `192.168.10.*`, Home-Server (Bridge) im `192.168.8.*`.
- Govee-LAN-**Discovery** läuft per Multicast (`239.255.255.250:4001`) und
  **überquert VLAN-Grenzen nicht** → **kein Auto-Discovery**. Stattdessen feste
  IPs (DHCP-Reservierung) + **Unicast**.
- Router/Firewall muss erlauben: Unicast-UDP `192.168.8.x → 192.168.10.x:4003`
  (Befehle) **und** Rückweg `192.168.10.x → 192.168.8.x:4002` (devStatus).
- Voraussetzung pro Lampe: LAN-Control im Govee-Home-App aktiviert
  (siehe Govee WLAN-/LAN-Guide).

## Govee LAN-Protokoll (Kurzreferenz)

Drei UDP-Ports:

- **4001** — Multicast-Discovery (nutzen wir nicht, VLAN-Grenze).
- **4003** — Steuerbefehle: Client → Lampe.
- **4002** — Antworten: Lampe → Client (eigener gebundener Listener-Socket).

Befehls-JSON (an `IP:4003`):

```json
{ "msg": { "cmd": "turn",       "data": { "value": 1 } } }
{ "msg": { "cmd": "brightness", "data": { "value": 50 } } }
{ "msg": { "cmd": "colorwc",    "data": { "color": { "r": 255, "g": 100, "b": 0 }, "colorTemInKelvin": 0 } } }
{ "msg": { "cmd": "devStatus",  "data": {} } }
```

**Wichtig:** Steuerbefehle (`turn`/`brightness`/`colorwc`) senden **keine**
automatische Bestätigung. Nur ein **`devStatus`-Request** löst eine Antwort auf
Port 4002 aus. Schalt-Bestätigung = Befehl senden → direkt danach `devStatus`
anfragen → Antwort abwarten → **Soll mit Ist vergleichen**. Bleibt die Antwort
aus → Fehler (Lampe stromlos/nicht erreichbar).

`devStatus`-Antwort (von `IP:4002`) enthält `onOff`, `brightness`, `color`,
`colorTemInKelvin` und (modellabhängig) `sku`/Modell.

## Architektur-Überblick

```
Befehl:     Web → GoveeCommander → MQTT(govee/<key>/command/*) → BRIDGE → UDP:4003 → Lampe
Bestätigung:Lampe → UDP:4002 → BRIDGE → MQTT(govee/<key>/status) → GoveeStatusSubscriber → DB(LightState) → ActionCable → UI
Polling:    BRIDGE schickt periodisch devStatus an alle Lampen-IPs → selber Rückweg
```

Die Bridge ist ein **reiner MQTT↔UDP-Übersetzer**: sie empfängt Befehle über
MQTT und schreibt Status wieder nach MQTT. Sie schreibt **nicht** in die DB. Der
Collector bleibt UDP-frei und damit schlank; er bekommt nur einen kleinen
zusätzlichen MQTT-Konsumenten für Lampen-Status. (Perspektivisch ließe sich
Solakon in dieselbe Bridge-Welt migrieren — *out of scope*.)

## Komponenten

### `lib/govee_lan_client.rb` (neu)

Reine Protokoll-Schicht, kein MQTT, keine DB. Unabhängig testbar mit
injizierbarem UDP-Socket-Factory (Muster `FritzDectClient`/`PlugCommander`
mit `*_factory`).

- Serialisiert `turn` / `brightness` / `colorwc` / `devStatus` zu JSON.
- Sendet Unicast-UDP an `IP:4003`.
- Parst `devStatus`-Antworten zu einem Struct (`on`, `brightness`,
  `color_r/g/b`, `color_temp_k`, `sku`).

### `lib/govee_mqtt_bridge.rb` + `bin/govee_bridge` (neu)

Langläufer-Prozess, der **einzige** Ort mit UDP. Lädt Rails-Env wie
`bin/ziwoas_collector` und liest die Lampen-Liste (Keys + IPs) **lesend** aus der
DB (`Light.all`, periodisch aktualisiert). Drei Aufgaben in Threads:

1. **Command-Consumer:** subscribed `govee/<key>/command/#`, übersetzt nach
   Govee-LAN-JSON via `GoveeLanClient`, sendet an `IP:4003`, fragt direkt `devStatus`
   an.
2. **Listener:** bindet **einmalig** UDP `:4002`, empfängt alle devStatus-Antworten,
   korreliert nach Quell-IP, publiziert `govee/<key>/status` (JSON mit
   `on`/`brightness`/`color`/`temp`/`reachable`).
3. **Poller:** schickt periodisch (konfigurierbares Intervall) `devStatus` an alle
   bekannten Lampen-IPs → erkennt auch Änderungen aus der Govee-App und
   stromlose Lampen (`reachable: false` bei Timeout).

`bin/govee_bridge` startet die Threads + Signal-Handling analog
`bin/ziwoas_collector`.

### `lib/govee_status_subscriber.rb` (neu, läuft im Collector)

Kleiner MQTT→DB-Konsument analog `MqttSubscriber`: subscribed
`govee/+/status`, schreibt `LightState.record_state(...)` (nur bei Änderung) und
broadcastet via ActionCable an die Switches-Seite. Wird als zusätzlicher Thread in
`bin/ziwoas_collector` gestartet. Hält den Collector UDP-frei.

### `lib/plug_commander.rb` (verschoben) + `lib/govee_commander.rb` (neu)

`PlugCommander` wird von `app/models/` nach `lib/` verschoben — Commander sind die
**Sende-Seite des Transports** (MQTT-Publish) und gehören zur selben
Infrastruktur-Ebene wie `mqtt_subscriber`/`fritz_mqtt_bridge`/`*_client`.
`plug_switches_controller` + Test-Require werden angepasst (kleiner
Mitnahme-Schritt).

`GoveeCommander` (neu, `lib/`) ist der web-seitige Choke-Point analog
`PlugCommander`: validiert (Lampe existiert, Wertebereiche) und publiziert den
passenden MQTT-Command. Kein UDP, keine DB. Methoden grob:
`turn(light, on:, source:)`, `set_brightness(light, value:, source:)`,
`set_color(light, r:, g:, b:, temp_k:, source:)`.

## Datenmodell (DB, UI-verwaltet)

Plugs bleiben weiterhin reine YAML-Config. Lampen sind **neu und DB-gestützt**,
weil sie per UI angelegt werden.

### `Light`

| Feld | Typ | Notiz |
|------|-----|-------|
| `key` | string, unique | Slug `/[a-z0-9_]+/`, MQTT-Topic-Segment; **auto-generiert aus `name`** |
| `name` | string | Anzeigename |
| `room` | string, optional | |
| `ip_address` | string | feste IP der Lampe |
| `sku` | string, optional | Govee-Modell, autom. via devStatus befüllbar |
| `shelly_plug_id` | string, optional | referenziert einen Config-Plug (Stromversorgung) |
| `supports_color` | bool | Fähigkeit (autom. via devStatus) |
| `supports_color_temp` | bool | Fähigkeit (autom. via devStatus) |

Validierungen analog `PlugValidator` (Key-Regex, Eindeutigkeit, IP-Format).
`shelly_plug_id` wird gegen die Config-Plugs validiert (muss existieren, wenn
gesetzt).

**Key-Generierung:** `key` wird beim Anlegen aus `name` slugifiziert
(klein, `[a-z0-9_]`, Rest → `_`). Kollision → numerisches Suffix
(`wohnzimmer`, `wohnzimmer_2`, …). Der Key wird in der DB persistiert und ist
danach **stabil** (MQTT-Topic-Segment darf sich nicht mehr ändern, auch wenn der
Name umbenannt wird).

### `LightState` (Muster `PlugState`)

`light_key` (unique), `on` (bool), `brightness` (0–100), `color_r/g/b`,
`color_temp_k`, `reachable` (bool), `last_seen_at`. Klassenmethode
`record_state(light_key, attrs)` schreibt nur bei tatsächlicher Änderung
(„record only on change", wie `PlugState.record_output`).

### Szenen: `Preset`, `Scene`, `SceneEntry`

Zweistufig, sauber speicher- und validierbar:

- **`Preset`** — wiederverwendbarer **Einzel-Lampen-Zustand**: `name`, `on`,
  `brightness`, `color_r/g/b`, `color_temp_k`. Lampen-unabhängig
  (z. B. „Warm 20 %", „Hell kalt", „Aus").
- **`Scene`** — `name`, `has_many :scene_entries`.
- **`SceneEntry`** — `scene_id`, `light_key`, `preset_id`. Bildet pro Lampe ein
  Preset ab.

**Szene anwenden** = je `SceneEntry` ein `GoveeCommander`-Befehl (das Preset auf
die Lampe). Wird über die normale Bridge-Strecke geschaltet und bestätigt.

## Web-UI (`/switches`)

Auf der bestehenden Switches-Seite ein **eigener Abschnitt „Lampen"**, getrennt
von den Energie-Plugs.

### Steuerung

- Pro Lampe eine Karte: Toggle (on/off), Helligkeits-Slider (0–100),
  Farbwähler (RGB) + Warm/Kalt-Slider (Farbtemperatur).
- Befehle **debounced** aus einem Stimulus-Controller `lights_controller.js`
  (mirroring `switches_controller.js`) — kein UDP-Spam pro Slider-Tick; Senden bei
  Loslassen/Debounce.
- Controller posten an `LightSwitchesController` (Befehle).

### Zustands-Feedback (Variante a, async)

1. Klick/Drag → `lights_controller.js` setzt die Karte sofort auf **„pending"**
   (sichtbares Feedback, dass etwas passiert) und postet den Befehl.
2. `LightSwitchesController` → `GoveeCommander` publiziert MQTT-Command, antwortet
   optimistisch (kein Warten auf das Gerät, blockiert keinen Puma-Thread).
3. Bridge → UDP → devStatus → `govee/<key>/status` → `GoveeStatusSubscriber`
   schreibt `LightState` + ActionCable-Broadcast.
4. `lights_controller.js` empfängt den Broadcast → Karte springt **final** auf den
   bestätigten Zustand und löscht „pending".
5. Kommt binnen Timeout (JS-seitig) kein Broadcast → Karte zeigt
   **„nicht bestätigt / Fehler"** (analog zum heutigen MQTT-Fehlerpfad bei
   Shellys).

### CRUD

- `LightsController` — Lampen anlegen/bearbeiten/löschen. Anlage: Name, Raum,
  feste IP, optional Shelly-Verknüpfung.
- **„Verbindung testen"** beim Speichern: App publiziert ein **Refresh-Signal**
  über MQTT (z. B. `govee/<key>/command/refresh`); die Bridge liest `Light.all`
  neu (die Lampe ist evtl. gerade erst angelegt) und schickt ein `devStatus` an die
  IP. Die Antwort fließt über die normale Strecke zurück (`govee/<key>/status` →
  `LightState`), befüllt `sku`/Fähigkeiten und bestätigt Erreichbarkeit; die UI
  zeigt das Ergebnis async (gleiches Pending→final-Muster).
- `LightPresetsController` / `ScenesController` — Presets & Szenen verwalten,
  Szene anwenden.

## Konfiguration

Neue `govee:`-Sektion in `ziwoas.yml` (nur Bridge-Settings; Lampen selbst sind
DB):

```yaml
govee:
  topic_prefix: govee        # MQTT-Topic-Präfix (Befehl + Status)
  poll_interval_seconds: 30  # devStatus-Polling der Lampen
  command_port: 4003
  listen_port: 4002
```

Neuer `GoveeCfg`-Struct + `build_govee` im `ConfigLoader`, mit
require-/Default-Logik im Stil der bestehenden Sektionen (`solakon`/`mqtt`).
Bridge ist nur aktiv, wenn `govee:` gesetzt ist.

## Abhängigkeiten

Keine neuen Gems. MQTT läuft über das bestehende **`mqtt`-Gem (ruby-mqtt,
v0.7.0)** — dasselbe wie `PlugCommander`/`MqttSubscriber`/`FritzMqttBridge`.
UDP über Rubys Standard-`UDPSocket`. Slugify ohne Zusatz-Gem (eigene kleine
Hilfsmethode, ASCII-Transliteration für Umlaute).

## Tests (spiegeln vorhandene Muster)

- **`GoveeLanClient`** — Serialisierung der Befehle + Parsing der devStatus-Antwort
  mit Fake-UDP-Socket (Muster `FritzDectClient`-Test).
- **`GoveeMqttBridge`** — MQTT-Command → UDP-Send; UDP-Antwort → MQTT-Publish; mit
  injizierten Fakes (Muster `FritzMqttBridge`-Test).
- **`GoveeStatusSubscriber`** — `govee/<key>/status` → `LightState.record_state` +
  Broadcast (Muster `MqttSubscriber`-Test).
- **`GoveeCommander`** — korrektes MQTT-Topic/Payload je Befehl, Validierung
  (Muster `PlugCommander`-Test).
- **`PlugCommander`** — bestehender Test mit verschobenem Require weiter grün.
- **Modelle** — `Light`/`LightState`/`Preset`/`Scene`/`SceneEntry`-Validierungen,
  `record_state` nur bei Änderung.
- **Controller** — `LightsController` (CRUD), `LightSwitchesController` (Befehl
  happy + Fehlerpfad), Szene anwenden.
- **`ConfigLoader`** — `govee:`-Parsing inkl. Defaults und Fehlerfälle.

## Bewusst ausgeklammert (YAGNI)

- Govee Cloud-API / Szenen über die Cloud.
- Govee-native LAN-Szenen-Codes (`ptReal`) — ersetzt durch lokale Presets/Szenen.
- Auto-Discovery (scheitert an der VLAN-Grenze).
- Migration der Solakon-Anbindung in die Bridge-Welt (eigenes Ticket).
- Synchrone Schalt-Bestätigung im Request (Variante b) — bewusst async gewählt.

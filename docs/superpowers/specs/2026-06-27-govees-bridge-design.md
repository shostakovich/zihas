# Design: `govees` — Maßanzug-Bridge statt govee2mqtt

**Datum:** 2026-06-27
**Branch:** `feature/govee-lights` (Worktree `.worktrees/govee-lights`)
**Status:** Design abgenommen, Spec zum Review

## Kontext & Motivation

Die App steuert Govee-Lichter aktuell über das externe Tool **govee2mqtt** (Rust)
via MQTT (`gv2mqtt/…`). Das funktioniert, hat aber im Zusammenspiel mit ziwoas
Reibung — vor allem **verzögerte Bestätigung** und **kein zeitnaher Reconcile**
externer Änderungen. govee2mqtt pollt träge (>45 s) und ist als
Home-Assistant-Generalist auf vieles ausgelegt, das wir nicht brauchen (AWS-IoT,
BLE, HASS-Schema), während wir Quirks beim Consumen nachpatchen müssen.

Wir ersetzen govee2mqtt durch eine **schlanke, eigene Ruby-Bridge `govees`**
(Namensgebung analog zu `shellies`), die genau das kann, was ziwoas braucht.
Dies ist die verbesserte Wiederauflage der früher gelöschten Eigenbau-Bridge
(`GoveeLanClient`/`GoveeMqttBridge`): diesmal **LAN + Platform-API** (statt
LAN-only), mit in der Bridge gefixten Quirks und sauberem Reconcile.

### Was govee2mqtt nicht nutzt/brauchte (entfällt)

AWS-IoT-Push (undokumentierte Account-API, P12-Zertifikate, mTLS), BLE,
HASS-Discovery-Schema, der `gv2mqtt`-Prefix, die Rust-Build-Pipeline
(`vendor/govee2mqtt`, Brewfile-Rust, gepinntes Binary).

### Grounding (am echten Konto verifiziert, 2026-06-27)

Die **dokumentierte Platform-API** (`https://openapi.api.govee.com`, Header
`Govee-API-Key`, **nur** API-Key — kein Account-Login) deckt alles ab, was wir
nutzen. Das frühere HTTP-454 war VPN-Routing (Govee-IP ist jetzt außen
herumgeroutet), kein Govee-Throttling. `/router/api/v1/user/devices`,
`/device/state`, `/device/control`, `/device/scenes` antworten sauber.

Fünf Geräte am Konto:

| Gerät | sku | Besonderheit |
|---|---|---|
| Floor Lamp 2 | H607C | gradient/pillar/base-Toggles, Szenen |
| Floor Lamp Krabbe | H607C | s. o. |
| Uplighter Floor Lamp | H60B0 | ripple/side/bottom-Zonen |
| Wall Sconces | H6038 | left/right-Toggles |
| Abendrot | DreamViewScenic | nur `powerSwitch`; `/device/state` wirft Fehler |

**Schlüssel-Erkenntnis:** `/device/state` liefert **mehr** als gedacht. Für den
Uplighter (H60B0) kommen echte Zonen-Toggle-Werte zurück
(`rippleLightToggle=1, sideLightToggle=0, bottomLightToggle=1`) — genau die
Telemetrie, die govee2mqtt nie liefern konnte. Verifiziert: **nur der H60B0**
meldet Zonen-State; H607C (`pillar/base/gradient`) und H6038 (`left/right`)
liefern die Toggles **leer (`""`), auch eingeschaltet** (Power-Status-Hypothese
widerlegt durch Anschalten beider). Ebenfalls in `/device/state`: `online`
(Reachability) und `lightScene` (aktive Szene, aktuell leer). `/device/control`
spiegelt eigene Befehle sofort (z. B. `powerSwitch` 0→1).

## Ziele / Nicht-Ziele

**Ziele**
- Schnelle, lokale Steuerung + Bestätigung über LAN für an/aus, dimmen, Farbe,
  Farbtemperatur.
- Eventually-consistent Reconcile: erkennt externe Änderungen (Fernbedienung/App)
  und korrigiert die Anzeige.
- Quirks **in der Bridge** lösen, nicht beim Consumen.
- ziwoas-Funktionalität **bleibt wie jetzt**; UI unverändert.
- Drop-in & reversibel: MQTT bleibt Vertragsgrenze.

**Nicht-Ziele (Out of Scope)**
- Segmente (Govee-seitig tot — `code:200`, kein Rendering) und Pro-Zonen-Farbe
  (Hardware: Welle+Seite teilen einen RGB-Kanal).
- AWS-IoT-Push, BLE, Account-Login/Cloud-Raumnamen.
- Live-Spiegelung schneller als der LAN-Poll.
- Aktive-Szene-Anzeige (heute nicht in der UI → YAGNI).

## Architektur

### Topologie

Ruby-Threads **im bestehenden `bin/ziwoas_collector`** (wie früher
`GoveeMqttBridge`) — kein eigenes Binary, kein eigener Container. Die Bridge
spricht mit den Lampen (LAN + Platform-API) und published auf MQTT unter
`govees/…`. Die Collector-Handler im selben Prozess konsumieren das über den
MQTT-Broker. MQTT bleibt bewusst als Vertragsgrenze → drop-in, reversibel,
unabhängig testbar.

```
Lampen (LAN-first, API-second)
   ▲ ▼  LAN devStatus/control (schnell) · Platform-API (Reconcile/Zonen/Szenen)
Govees::Bridge (Ruby, im Collector)
   │  Quirks gefixt · optimistischer State + Reconcile
   ▼  MQTT  govees/<id>/{config,state}   ▲  govees/<id>/set
MqttRouter + dünne Handler  →  LightState / Light  →  ActionCable/Turbo  →  UI
```

### Komponenten (`lib/govees/`)

- **`Govees::LanClient`** — UDP. Multicast-Discovery (`scan` an
  `239.255.255.250:4001`, Antwort auf `:4002`), Steuerung (`turn`/`brightness`/
  `colorwc` an `:4003`), `devStatus`-Read. Wiederauflage des gelöschten
  `GoveeLanClient` + Discovery. Wire-Format JSON (`{"msg":{"cmd":..,"data":..}}`).
- **`Govees::PlatformApi`** — REST-Client (`/user/devices`, `/device/state`,
  `/device/control`, `/device/scenes`), API-Key-only, rate-limit-bewusst, kleiner
  TTL-Cache. Status-Codes liegen im JSON-Body (`{"code":200,…}`), nicht im HTTP-Code.
- **`Govees::DeviceRegistry`** — bekannte Lampen; merged LAN (IP/sku/MAC) + API
  (Capabilities/Name/Szenen). Kuratiert: Segmente raus, Zonen auf echte Toggles,
  Szenen als saubere Namensliste (+ internes Name→`{id,paramId}`-Mapping).
- **`Govees::StateStore`** — pro Lampe `desired` (optimistisch) + `confirmed`
  (Telemetrie) + Status `SYNCED|PENDING|RECONCILING`. Enthält die
  **Konflikt-Logik**. Injizierbare Uhr (testbar).
- **`Govees::Reconciler`** — LAN-Tick (~5–10 s/Lampe), API-Tick (≤ alle 3 min),
  On-Demand-API-Klärung bei „an + Abweichung".
- **`Govees::CommandRouter`** — `govees/<id>/set` → LAN oder API je Capability;
  published optimistisch sofort.
- **`Govees::Bridge`** — Orchestrator; startet/überwacht die Threads
  (Supervisor-Muster wie die Fritz-Bridge im Collector).

## Befehls-Routing (LAN vs. API hängt am Befehlstyp)

Das dokumentierte LAN-Protokoll kann nur ganze-Lampe-Befehle. Zonen & Szenen
müssen über die Cloud.

| Befehl | Weg | Bestätigung |
|---|---|---|
| Power (ganze Lampe), Helligkeit, RGB, Farbtemperatur | **LAN** (primär), API-Fallback | LAN-Read-back ~1–2 s |
| Status lesen (`devStatus`) | **LAN** | ist der schnelle Reconcile |
| Zonen-Toggle (ripple/side/bottom/left/right/pillar/base) | **nur API** | H60B0: nächster API-Poll; sonst optimistisch |
| Szene (`lightScene`/`diyScene`) | **nur API** | keine Telemetrie → rein optimistisch |
| Sonderfall „Abendrot" (DreamViewScenic, nur `powerSwitch`) | API | optimistisch |

## Reconcile- & Konflikt-Logik

Pro Lampe vergleicht die Bridge eingehende Telemetrie gegen den **veröffentlichten
State** (der während PENDING = `desired` ist).

**① Befehl von ziwoas**
1. `desired` setzen, **sofort** optimistisch publishen (UI bestätigt < 100 ms),
   Status `PENDING`.
2. An Lampe senden (LAN primär, API-Fallback bzw. API-only für Zonen/Szenen).
3. Nach ~1–2 s LAN-Read-back: == `desired` → `SYNCED`. Sonst innerhalb des
   PENDING-Fensters (~5 s) retry/warten; nach Ablauf gewinnt der Poll.

**② LAN-Poll-Tick (~5–10 s)** — Vergleich mit veröffentlichtem State:
- Während PENDING gilt eine Abweichung als „noch nicht angewendet" → warten, kein
  Fehlalarm „extern geändert".
- **Lampe sagt AUS** → „aus ist aus", sofort übernehmen + publishen.
- **AN, aber Helligkeit/Farbe weicht ab** → `RECONCILING`, **einmalig** API-Klärung
  (volles Bild holen statt LAN blind flappen). Praktisch nur beim H60B0 nötig
  (wegen Zonen); bei H607C/H6038 reicht LAN.
- passt → nichts tun.

**③ API-Poll (≤ alle 3 min) + On-Demand aus ②** — übernimmt alles, was die API
liefert: on/Helligkeit/RGB/Temp + `online` für alle; **Zonen-State nur H60B0**;
aktive Szene nur falls je gefüllt. Danach `SYNCED`.

**Kernregeln:** (1) Eigene Befehle gegen `desired` vergleichen, nicht gegen alt.
(2) Aus ist via LAN sofort vertrauenswürdig. (3) An+Abweichung → API-Klärung.
(4) Der API-Poll fängt zusätzlich, was LAN nicht sieht (Zonen/online/Szene).

## MQTT-Vertrag (`govees/…`, abgespeckt auf das real Genutzte)

**`govees/<id>/config`** (retained):
```json
{ "sku": "H60B0", "name": "Uplighter Floor Lamp",
  "supports_color": true, "supports_color_temp": true,
  "zones": ["rippleLightToggle", "sideLightToggle", "bottomLightToggle"],
  "scenes": ["Sunset", "..."] }
```

**`govees/<id>/state`** (retained):
```json
{ "on": true, "brightness": 50,
  "color": {"r":0,"g":0,"b":255}, "color_temp_k": null,
  "reachable": true, "zone_states": {"ripple": true} }
```
`color` **oder** `color_temp_k` ist gesetzt (der andere `null`) — das sagt den
Modus; kein separates `color_mode`-Feld. `brightness` ist 0–100. Der Handler
stempelt `last_seen_at` beim Empfang selbst.

**`govees/<id>/set`** — ein Verb pro Nachricht:
```
{"power":"on"|"off"} · {"brightness":50} · {"color":{"r":..,"g":..,"b":..}}
{"color_temp_k":3000} · {"zone":{"name":"ripple","on":true}} · {"scene":"Sunset"}
```

## Quirks — in der Bridge gelöst (nicht mehr im Consumer)

1. Segment-Entities werden gar nicht erst emittiert.
2. Zonen kuratiert: die Bridge entscheidet anhand `Light::ZONE_META.keys` (DRY,
   eine Quelle), welche Toggles echte Zonen sind, und emittiert nur deren Keys.
   Die deutschen Labels/Rollen bleiben app-seitig in `Light::ZONE_META` (UI-Copy,
   kein Bridge-Belang) — der Vertrag trägt nur Zonen-Keys.
3. Szenen als saubere Namensliste aus der Platform-API (kein `effect_list`-Parsing,
   keine `select`-Topic-Jagd).
4. Kelvin nativ — keine Mired-Umrechnung mehr.
5. Helligkeit nativ 0–100 % — keine 0–254-HA-Skala.
6. Power als ein Begriff — Bridge regelt intern `powerSwitch` vs. Haupt-Licht.
7. `color_mode` von der Bridge aufgelöst; Consumer bekommt klare Felder.
8. DreamViewScenic-Sonderfall sauber gekapselt (power-only) statt Crash.

## Konfiguration

`config/ziwoas.yml` + Secret:
- **API-Key** aus env (wie heute, `GOVEE_API_KEY`).
- **MQTT-Host** (bestehend, `mqtt.host`).
- **Poll-Takte + PENDING-Fenster** mit Defaults (LAN-Tick ~5–10 s, API ≤ 3 min,
  PENDING ~5 s).
- **Klarnamen / Raum-Mapping pro Gerät** in der yml (API-Key-only liefert keine
  Cloud-Raumnamen).

## Fehlerbehandlung

- LAN tot für eine Lampe → API-Fallback fürs Steuern + `online`/Reachability aus
  API; beides tot → `reachable:false`.
- API-Fehler (454/5xx) → Backoff + Cache servieren, **nicht crashen** (die
  govee2mqtt-#76-Lektion).
- Defekte Geräte-Antwort (Abendrot/`/device/state`-Fehler) → abgefangen,
  als power-only behandelt.
- Bridge-Thread-Crash → Supervisor-Restart im Collector.

## Tests (TDD)

- **`LanClient`** — Paket-Encode/Decode (`scan`/`turn`/`brightness`/`colorwc`/
  `devStatus`) gegen Fake-UDP-Socket.
- **`PlatformApi`** — Request-Bau + Response-Parsing gegen **die echten Antworten
  als Fixtures** (`/user/devices`, `/device/state` je sku, `/device/scenes`);
  Backoff/Negative-Cache.
- **`StateStore`/Konflikt-Logik (Herzstück)** — reine Unit-Tests mit injizierbarer
  Uhr: PENDING-Fenster, aus-ist-aus, an+Abweichung→Reconcile, eigene Befehle nicht
  als „extern".
- **`CommandRouter`** — Routing je Capability (power→LAN, zone→API, scene→API),
  optimistisches Publish.
- **`Reconciler`** — Tick-Verhalten (LAN/API) treibt den Store korrekt.
- **Handler** (dünn) — neuer `govees/`-Vertrag → `LightState`/`Light`.
- **End-to-end** — Bridge mit Fake-LAN+API → MQTT → Handler → `LightState`.

## Migration / Auswirkungen

**Entfällt:** govee2mqtt-Binary, `vendor/govee2mqtt`, Brewfile-Rust,
`config/govee2mqtt.env`, Procfile-/Docker-govee2mqtt-Prozess, `gv2mqtt`-Prefix,
`docs/govee2mqtt-setup.md`.

**Umgebaut:** die bestehenden Handler (`GoveeDiscoveryHandler`,
`GoveeStatusHandler`, `GoveeZoneDiscoveryHandler`, `GoveeZoneStateHandler`) →
schlanker gegen den `govees/`-Vertrag; `GoveeCommander` → `Govees::CommandRouter`.

**Bleibt (funktional wie jetzt):** Models (`Light`/`LightState`/`Room`/`Scene`/
`Preset`), `LightSwitchesController` (ggf. kleine `set`-Payload-Anpassung),
`MqttRouter`, ActionCable/Turbo-Broadcasting, gesamte UI.

## Offene Punkte für die Umsetzung

- Bestätigen, dass H60B0-Zonenwerte echte Telemetrie sind (nicht nur
  Govee-Cache des letzten Befehls) — per externem Umschalten + Re-Poll.
- `lightScene` bei aktiver Szene gegenchecken (ob je gefüllt) — beeinflusst nur
  ein evtl. späteres Feature, nicht den jetzigen Scope.
- Exakte LAN-`devStatus`-Felder pro sku gegen die Realität verifizieren (color
  vs. colorTemInKelvin, brightness 0–100).

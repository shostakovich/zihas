# Lampen-Detail-Widget: Umbau auf Turbo + Hotwire

**Datum:** 2026-06-27
**Status:** Design freigegeben, bereit für Implementierungsplan

## Problem

Das Lampen-Detail-Widget (`app/views/lights/show.html.erb`) wird heute von einem
188-Zeilen-Stimulus-Controller (`light_detail_controller.js`) getrieben, der fast
die gesamte Interaktion in JavaScript abwickelt: optimistisches DOM-Mutieren,
Reconcile gegen rohes ActionCable-JSON (`onBroadcast`), Zonen-Toggle inkl.
max-2-auto-off, Toast/Undo. Das ist mehr Client-Logik als nötig und widerspricht
der Präferenz, in Rails-Projekten Turbo + Hotwire zu nutzen und Stimulus nur für
das einzusetzen, was wirklich JavaScript braucht.

**Konkreter Bug, der dadurch sichtbar wurde:** Zonen-Zustände überleben keinen
Reload. Ursache (am Quellcode bestätigt): `LightSwitchesController#create` →
`GoveeCommander.set_zone` publiziert nur den MQTT-Command, schreibt aber
`LightState#zone_states` nie. Der einzige Schreiber von `zone_states` ist
`GoveeZoneStateHandler`, der auf eingehende `gv2mqtt/switch/<key>/<zone>/state`-
Topics reagiert — die govee2mqtt für Zonen aber niemals publiziert
(`vendor/govee2mqtt/src/hass_mqtt/switch.rs:97-142`: nur `powerSwitch` bekommt
einen State; für andere Switch-Instanzen liefert Govee keine Daten). Das alte JS
schaltet die Zonen-Karte nur optimistisch im DOM um — beim Reload liest der Server
`zone_states = {}` und rendert alles „aus". Der Umbau persistiert den Befehl
server-seitig und behebt den Bug als Nebeneffekt.

## Ziele

- Das Detail-Widget so weit wie sinnvoll auf server-gerenderte Turbo Streams
  umstellen; Stimulus nur für echtes JS (Slider, Tabs, Toast-Timer).
- Zonen-Zustand server-seitig persistieren → übersteht Reload.
- Eine einzige Render-Quelle pro UI-Fragment (Partial), keine Duplikation
  zwischen ERB und JS.

## Scope

**Im Scope:** Nur das Detail-Widget — `app/views/lights/show.html.erb`,
`app/controllers/light_switches_controller.rb`, `light_detail_controller.js`,
neue Partials, der per-Lampe-Turbo-Stream-Broadcast aus dem Collector.

**Nicht im Scope:** Die „Schalten"-Tab-Kacheln (Index/Switches). Der bestehende
rohe `"dashboard"`-ActionCable-Kanal bleibt **unangetastet und parallel erhalten**
— ich ergänze einen per-Lampe-Turbo-Stream, ersetze den `dashboard`-Kanal nicht.

## Architektur

Drei sauber getrennte Schichten:

### 1. Server rendert Wahrheit (Partials)

Jedes veränderliche UI-Fragment wird in ein Partial ausgelagert, das sowohl
`show.html.erb` initial rendert als auch die Turbo-Stream-Antworten/-Broadcasts
liefern:

- `lights/_zone.html.erb` — eine Zonen-Karte (DOM-ID `zone_<key>`).
- `lights/_power.html.erb` — Hero + An/Aus-Pills (DOM-ID `light_power`).
- `lights/_toast.html.erb` — Toast mit Undo-`button_to` (DOM-ID `light_toast`).

Eine Render-Quelle, kein Duplikat zwischen ERB und JS.

### 2. Commands → Turbo Stream statt fetch+DOM

`LightSwitchesController#create` antwortet je nach Befehl mit `turbo_stream`-
Replace der betroffenen Fragmente.

- **Power/Presets/Swatches/Szenen/Moods:** werden zu `button_to` (Turbo-Form).
  Power-Antwort ersetzt `light_power`.
- **Zonen-Toggle (`command=zone`):**
  1. `LightState.record_zone_state(key, zone, on)` — **persistiert zuerst** (der
     fehlende Schritt, der den Bug verursacht).
  2. `GoveeCommander.set_zone` — MQTT-Command wie bisher.
  3. **max-2-auto-off:** Wird eine `side`-Zone eingeschaltet und sind bereits
     `max_active_zones` Seiten an, wählt der Controller ein Opfer, schaltet es aus
     (persist + MQTT) und merkt sich Opfer+Neu für Undo.
     - **Opfer-Wahl (Entscheidung B, YAGNI):** deterministisch die *andere*
       an-Seiten-Zone. Bei H60B0 gibt es nur Welle + Seite → eindeutig. Keine
       Aktivierungs-Reihenfolge mitführen, bis es eine Lampe mit ≥3 Seiten-Zonen
       gibt.
  4. **Antwort:** Turbo Stream replaced die betroffene(n) Zonen-Karte(n) und —
     bei Eviction — das Toast-Partial.
- **Undo (`command=zone_undo`, params `victim`/`added`):** Opfer wieder an, Neu
  aus, beide persistieren + MQTT, Turbo Stream räumt Toast weg und stellt beide
  Karten. Rein server-seitig, kein JS-Zustand.

### 3. Reconcile externer Änderungen → per-Lampe Turbo Stream

- Die Detailseite abonniert `turbo_stream_from "light_#{@light.key}"`.
- Der Collector broadcastet bei MQTT-State zusätzlich
  `Turbo::StreamsChannel.broadcast_replace_to "light_#{key}", ...` mit demselben
  Partial.
- **Granularität bewusst eng:** Broadcasts ersetzen nur **Power-Zustand**
  (`light_power`) und **Zonen-Karten** (`zone_<key>`) — also was sich extern
  ändert und zählt. **Slider werden NICHT live ersetzt** (sonst springt der Regler
  beim Ziehen); Helligkeit/Farbe gleichen sich beim nächsten Seitenaufruf ab.
- Der rohe `"dashboard"`-Broadcast bleibt parallel für die Switches-Seite.

## Verbleibendes JavaScript (schlank)

- `light-detail` (stark abgespeckt, ~40–50 statt 188 Zeilen): **Tabs** umschalten
  (reines View-State, kein Round-Trip) + **Slider** (Helligkeit, Farbtemperatur)
  und **Color-Wheel** als debounced fire-and-forget-POST. Kein DOM-Reconcile,
  kein `onBroadcast`, kein Zonen-/Toast-/Undo-Code mehr.
- `toast` (neu, winzig): nur 5s-Selbst-Entfernen-Timer. Der Undo-Button darin ist
  server-getrieben.

## Daten

Keine Migration. `zone_states` (JSON-Hash auf `LightState`) existiert und
persistiert bereits — es fehlte nur der Schreibaufruf im Command-Pfad.
`on`/Helligkeit/Farbe persistiert `GoveeStatusHandler` schon.

## Bewusster Tradeoff

Zonen-Toggle wartet auf die Server-Antwort (~50–100 ms lokal), kein optimistisches
Sofort-Aufleuchten. Dafür minimal JS und garantierte Korrektheit/Persistenz.
Vom Nutzer bestätigt („Voll server-driven").

## Tests (TDD)

- **Controller-Test:** `command=zone` persistiert `zone_states` **und** liefert
  `turbo_stream`; Eviction-Fall schaltet Opfer aus + rendert Toast; `zone_undo`
  macht beides rückgängig.
- **Reload-Regression:** Partial rendert aus persistiertem State —
  `zone_states = {"bottomLightToggle" => true}` → Karte „an".
- Bestehende Handler-Tests (`govee_zone_state_handler_test.rb` etc.) bleiben grün.

## Risiken / früh zu verifizieren

- Der Collector (separater Prozess) muss Partials rendern können für
  `broadcast_replace_to`. `turbo-rails` lädt die Rails-App im Collector ohnehin —
  früh im Plan verifizieren.
- `broadcast_replace_to` aus einem Nicht-Web-Prozess: ActionCable-Broadcasting
  (async/Redis-Adapter) muss korrekt konfiguriert sein — gegen die bestehende
  `ActionCable.server.broadcast`-Nutzung im Collector abgleichen.

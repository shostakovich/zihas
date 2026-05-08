# SwitchBot-Sensoren-Integration – Design (V1)

Datum: 2026-05-08
Autor: brainstorming session

## Ziel

Integration von zwei SwitchBot **Meter Pro CO₂ Monitoren** (Innenräume) und einem
SwitchBot **Outdoor Meter** (Außenthermometer/Hygrometer) in ZiWoAS. Die Werte
werden alle 15 Minuten via SwitchBot Cloud API v1.1 abgefragt, persistiert und in
einem neuen Tab "Sensoren" dargestellt. Die aktuelle Außentemperatur ergänzt
zusätzlich den bestehenden Wetter-Tab.

Zielgröße V1: **aktueller Zustand** aller Sensoren plus **24-Stunden-Verlauf** als
Charts. Keine Integration in Berichte, keine Push-Benachrichtigungen, keine
Heatmaps – diese Themen sind als V2+ vorgemerkt.

## Hintergrund: SwitchBot Cloud API

* Endpoint Statusabfrage: `GET https://api.switch-bot.com/v1.1/devices/{deviceId}/status`
* Auth: vier Header (`Authorization`, `t`, `nonce`, `sign`); `sign` ist
  HMAC-SHA256 über `token + t + nonce`, base64-encodiert
* Rate Limit: 10 000 Calls/Tag → 3 Sensoren × 96 Polls/Tag = 288 Calls
* **Keine historischen Werte** über die offizielle API – Historie wird selbst durch
  Polling aufgebaut
* Outdoor Meter (BLE-only) erfordert einen SwitchBot Hub im Setup; ist bereits
  vorhanden

### Antwortfelder

**Meter Pro CO₂** (`deviceType: "MeterPro(CO2)"`):

| Feld          | Typ     | Einheit / Anmerkung                     |
| ------------- | ------- | --------------------------------------- |
| `temperature` | Float   | °C                                      |
| `humidity`    | Integer | %                                       |
| `CO2`         | Integer | ppm, 0–9999                             |
| `battery`     | Integer | 0–100, kontinuierlich                   |
| `version`     | String  | Firmware                                |
| `hubDeviceId` | String  | Parent Hub                              |

**Outdoor Meter** (`deviceType: "WoIOSensor"`):

| Feld          | Typ     | Einheit / Anmerkung                                    |
| ------------- | ------- | ------------------------------------------------------ |
| `temperature` | Float   | °C                                                     |
| `humidity`    | Integer | %                                                      |
| `battery`     | Integer | **4-stufig**: <10→10, 10–20→20, 20–60→60, ≥60→100      |
| `version`     | String  | Firmware                                               |
| `hubDeviceId` | String  | Parent Hub                                             |

Kein RSSI, kein `lastUpdateTime` im Status (nur in Webhooks).

## Architektur

```
┌─────────────────────────────────────────────────────────────┐
│  config/recurring.yml                                       │
│  └── SensorPollJob: every 15 minutes                        │
└────────────┬────────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────────┐
│  SensorPollJob   (app/jobs/)                                │
│    iteriert konfigurierte Sensoren, ruft SwitchBotClient,   │
│    schreibt SensorReading-Zeilen, broadcastet Turbo-Stream  │
└────────────┬───────────────────────────────┬────────────────┘
             │                               │
             ▼                               ▼
┌─────────────────────────┐    ┌─────────────────────────────┐
│ SwitchBotClient         │    │ SensorReading (model)       │
│  (lib/)                 │    │  (db: sensor_readings)      │
│  • HMAC-Signatur        │    │  • taken_at, device_id,     │
│  • GET /devices/        │    │    temperature, humidity,   │
│    {id}/status          │    │    co2, battery_pct,        │
│  • Faraday + Timeout    │    │    firmware_version         │
└─────────────────────────┘    └────────────┬────────────────┘
                                            │
                                            ▼
                       ┌─────────────────────────────────────┐
                       │ SensorsController                   │
                       │  • #index → Tab "Sensoren"          │
                       │  • #series → JSON für Charts (24 h) │
                       │ (turbo_stream_from "sensors")       │
                       └─────────────────────────────────────┘
```

Konsistent zum Wetter-Modul (`WeatherCurrentJob`, `BrightskyClient`,
`WeatherController`). Sensor-Definitionen leben in der yml zur Laufzeit (analog
zu Plugs); in der DB liegen nur Messwerte.

## Datenmodell

### Migration `sensor_readings`

```ruby
create_table :sensor_readings do |t|
  t.string   :device_id,        null: false   # match auf yml-id
  t.datetime :taken_at,         null: false   # = Time.current beim Poll
  t.float    :temperature                     # °C
  t.integer  :humidity                        # %
  t.integer  :co2                             # ppm, NULL bei outdoor_meter
  t.integer  :battery_pct                     # 0–100 (outdoor: 10/20/60/100)
  t.string   :firmware_version                # Diagnostik
  t.timestamps
end

add_index :sensor_readings, [:device_id, :taken_at]
add_index :sensor_readings, :taken_at
```

Begründung:

* `device_id` als String, kein FK auf eine Sensors-Tabelle → spiegelt das
  Plug-Muster, Konfiguration bleibt in der yml
* `taken_at` separat von `created_at`, damit der Polling-Zeitpunkt fix bleibt
  (DB-Insert kann minimal verzögert sein)
* Alle Messfelder nullable: ein einzelner fehlender Wert killt nicht die ganze
  Zeile (z. B. wenn der Hub kurz keinen Kontakt zum Außensensor hat)
* `firmware_version` ist quasi gratis und nützlich für spätere
  Versions-bezogene Anomalien

### Modell `SensorReading`

```ruby
class SensorReading < ApplicationRecord
  scope :for_device, ->(id) { where(device_id: id) }
  scope :since,      ->(t)  { where("taken_at >= ?", t) }

  def self.latest_per_device(device_ids)
    where(device_id: device_ids)
      .where("taken_at = (SELECT MAX(taken_at) FROM sensor_readings sr2
                          WHERE sr2.device_id = sensor_readings.device_id)")
  end
end
```

### Datenmenge & Idempotenz

* 3 Sensoren × 96 Polls/Tag × 365 Tage ≈ 105 k Zeilen/Jahr → keine
  Retention-Policy in V1
* Bei Doppel-Trigger entstehen zwei Zeilen mit fast gleichem `taken_at`;
  akzeptabel, kein Unique-Constraint nötig

## Konfiguration

Erweiterung der `ziwoas.yml` und `ziwoas.example.yml`:

```yaml
switchbot:
  token:  "..."
  secret: "..."
  poll_interval_minutes: 15        # in Spec hardcodiert auf 15, hier nur dokumentiert

sensors:
  - id:   "ABCDEF123456"
    name: "Wohnzimmer"
    type: meter_pro_co2            # meter_pro_co2 | outdoor_meter
    room: "Wohnzimmer"             # optional

  - id:   "FEDCBA654321"
    name: "Schlafzimmer"
    type: meter_pro_co2
    room: "Schlafzimmer"

  - id:   "112233445566"
    name: "Balkon"
    type: outdoor_meter

# Bestehende plugs bekommen optionales room-Feld:
plugs:
  - id:   bkw
    name: Balkonkraftwerk
    role: producer
    room: "Balkon"                 # optional, neu
```

### `ConfigLoader`-Erweiterung (`lib/config_loader.rb`)

* Neuer Sub-Loader `switchbot:` → `Config::Switchbot` (Struct mit `token`,
  `secret`)
* Neuer Sub-Loader `sensors:` → Liste von `Config::Sensor` (Struct mit `id`,
  `name`, `type`, `room`)
* `type` wird als Symbol normalisiert (`:meter_pro_co2` / `:outdoor_meter`);
  unbekannte Werte → klare Fehlermeldung beim Start
* Optionales `room`-Attribut am bestehenden `Config::Plug`-Struct (default `nil`)

### Verhalten bei fehlenden Feldern

* Kein `switchbot:` Block → `SensorPollJob` macht nichts und loggt einmalig
  "Kein switchbot konfiguriert, übersprungen"
* Kein `sensors:` Block → analog
* `switchbot:` da, aber `token`/`secret` fehlen → harter Fehler beim Job-Start
  (Konfig-Fehler nicht stillschweigend tolerieren)

### Test-Konfiguration

`config/ziwoas.test.yml` bekommt einen Beispiel-Sensor-Block für die Tests
(analog zu vorhandenen Test-Plugs).

## SwitchBotClient (`lib/switch_bot_client.rb`)

```ruby
class SwitchBotClient
  BASE = "https://api.switch-bot.com"

  class Error < StandardError; end

  def initialize(token:, secret:, http: Faraday.new); end

  # Liefert normalisiertes Hash:
  #   :temperature, :humidity, :co2 (oder nil), :battery_pct, :firmware_version, :raw
  # Wirft SwitchBotClient::Error mit klarer Message bei API-Fehlern.
  def device_status(device_id); end

  # Für den Rake-Task:
  #   [{ id:, name:, type: }, ...]   gefiltert auf MeterPro(CO2) und WoIOSensor
  def list_sensor_devices; end

  private

  def signed_headers
    t     = (Time.now.to_f * 1000).to_i.to_s
    nonce = SecureRandom.uuid
    sign  = Base64.strict_encode64(
              OpenSSL::HMAC.digest("SHA256", @secret, "#{@token}#{t}#{nonce}")
            )
    { "Authorization" => @token, "t" => t, "nonce" => nonce, "sign" => sign,
      "Content-Type" => "application/json" }
  end
end
```

### Fehlerbehandlung im Client

* HTTP-Timeout (4 s) → `Error("timeout")`
* Non-200 oder API-`statusCode != 100` → `Error` mit Message aus `response.body.message`
* Parsing-Fehler → `Error("malformed response")`

## SensorPollJob (`app/jobs/sensor_poll_job.rb`)

```ruby
class SensorPollJob < ApplicationJob
  def perform
    config = ConfigLoader.load(...)
    return if config.switchbot.nil? || config.sensors.empty?

    client = SwitchBotClient.new(token: config.switchbot.token,
                                 secret: config.switchbot.secret)
    now    = Time.current

    config.sensors.each do |sensor|
      begin
        data = client.device_status(sensor.id)
        SensorReading.create!(device_id: sensor.id, taken_at: now,
                              **data.except(:raw))
      rescue SwitchBotClient::Error => e
        Rails.logger.warn("SensorPoll[#{sensor.id}]: #{e.message}")
        # nächster Sensor – ein toter Sensor blockt nicht die anderen
      end
    end

    SensorsBroadcaster.refresh   # Turbo-Stream "sensors"
  end
end
```

### Fehlerstrategie

* Pro Sensor isoliert: ein nicht erreichbarer Sensor lässt die anderen weiter
  loggen
* Keine eigenen Retries im Job – der nächste Lauf kommt in 15 Min;
  Retry-Spirals wären schädlich
* SolidQueue-Default-Retries bleiben (für echte Crashes)
* Bei Sensor-Fehler **keine Zeile schreiben** (besser eine Lücke im Chart als
  irreführende Werte)

### Scheduling (`config/recurring.yml`)

```yaml
poll_sensors:
  class: SensorPollJob
  queue: default
  schedule: every 15 minutes
```

### Live-Update

Nach erfolgreichem Poll broadcastet der Job auf den Stream `"sensors"`. Der
Sensor-Tab subscribed via `<%= turbo_stream_from "sensors" %>` und re-rendert
die Cards. Charts werden vom Stimulus-Controller alle 15 Min ohnehin neu geladen
(gleiche Mechanik wie `today_chart_controller.js`).

## Rake-Task (`lib/tasks/switchbot.rake`)

```bash
$ bin/rails switchbot:list_devices

Gefundene Geräte:
─────────────────────────────────────────────────────
  ABCDEF123456  Wohnzimmer       MeterPro(CO2)
  FEDCBA654321  Schlafzimmer     MeterPro(CO2)
  112233445566  Balkon           WoIOSensor
  AABBCCDDEEFF  Hub Wohnzimmer   Hub2          (Hub – kein Sensor)
─────────────────────────────────────────────────────

Konfigurations-Vorschlag für config/ziwoas.yml:

sensors:
  - id: "ABCDEF123456"
    name: "Wohnzimmer"
    type: meter_pro_co2
    room: "Wohnzimmer"     # ggf. anpassen

  - id: "FEDCBA654321"
    name: "Schlafzimmer"
    type: meter_pro_co2
    room: "Schlafzimmer"   # ggf. anpassen

  - id: "112233445566"
    name: "Balkon"
    type: outdoor_meter
```

Logik:

* Token/Secret aus `ziwoas.yml` (`switchbot:` Block) – muss vorher gefüllt sein
* Filtert: nur Sensor-Typen (`MeterPro(CO2)`, `WoIOSensor`); andere Geräte (z. B.
  Hub) werden separat als Info gezeigt
* Mappt Device-Type → unser `type:`-Feld (`MeterPro(CO2)` → `meter_pro_co2`,
  `WoIOSensor` → `outdoor_meter`)
* Übernimmt den Geräte-Namen aus der App als `name` und ersten `room`-Vorschlag

## UI: Sensoren-Tab (`/sensors`)

### Layout

```
┌── Sensoren ────────────────────────────────────────┐
│                                                    │
│  ⚠ Batterie schwach: Schlafzimmer (18 %)           │  nur wenn Sensor < 20 %
│                                                    │
│  Innenräume                                        │
│  ┌── Wohnzimmer ─────────────┐                     │
│  │                  🔋 85 %  │                     │
│  │                           │                     │
│  │  21.4 °C        ╭─────╮   │                     │
│  │  52 % rH        │  ⬤  │   │  Ampel hochkant    │
│  │  612 ppm        │  ○  │   │  rechts, ca. 72 px │
│  │                 │  ○  │   │  hoch              │
│  │                 ╰─────╯   │                     │
│  │  vor 2 Min                │                     │
│  └───────────────────────────┘                     │
│  (analog Schlafzimmer)                             │
│                                                    │
│  Außen                                             │
│  ┌── Balkon ─────────────────┐                     │
│  │  12.3 °C       🔋 100 %   │  keine Ampel       │
│  │  71 % rH                  │                     │
│  │  vor 2 Min                │                     │
│  └───────────────────────────┘                     │
│                                                    │
│  Tagesverlauf                                      │
│  ┌──────────────────────────────────────────────┐  │
│  │  Temperatur (24 h)                           │  │
│  │  [Linien-Chart: alle 3 Sensoren]             │  │
│  └──────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────┐  │
│  │  Luftfeuchtigkeit (24 h)                     │  │
│  │  [Linien-Chart: alle 3 Sensoren]             │  │
│  └──────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────┐  │
│  │  CO₂ (24 h)                                  │  │
│  │  [Linien-Chart: 2 Innensensoren,             │  │
│  │   Hintergrund-Bänder bei 1000 / 1400 ppm]    │  │
│  └──────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────┘
```

### Routes

```ruby
resources :sensors, only: [:index]
get "sensors/series", to: "sensors#series"
```

### Controller (`SensorsController`)

* `#index` – holt die letzte Lesung pro konfiguriertem Sensor
  (`SensorReading.latest_per_device(...)`), gruppiert nach `type`
  (indoor/outdoor), reicht das Config-Objekt zum Rendern durch (für
  Raum-/Sensor-Namen)
* `#series` – liefert JSON für die 3 Charts:
  `{ temperature: [...], humidity: [...], co2: [...] }`, je Reihe
  `{ device_id, name, points: [[ts,val], …] }` der letzten 24 h

### Views (`app/views/sensors/`)

* `index.html.erb` – Hauptseite mit `turbo_stream_from "sensors"`
* `_battery_warning.html.erb` – globale Warnung (rendert nur wenn min(battery)
  < 20)
* `_indoor.html.erb` – Sektion + Card-Loop für `meter_pro_co2`
* `_outdoor.html.erb` – Sektion + Card-Loop für `outdoor_meter`
* `_card.html.erb` – einzelne Sensor-Card, type-aware (zeigt CO₂ + Ampel nur
  bei indoor)
* `_charts.html.erb` – Container mit Stimulus-Controller `sensors-chart`

### Stimulus-Controller (`app/javascript/controllers/sensors_chart_controller.js`)

* Lädt `/sensors/series` beim Connect, baut die 3 Chart.js-Charts (vorhandene
  Vendor-Lib `chart.js` wird wiederverwendet)
* Refresh-Timer alle 15 Min (analog `today_chart_controller`)
* Re-load auch bei Turbo-Update der Page (Tab-Wechsel zurück)
* CO₂-Chart hat zwei horizontale Hintergrund-Bänder (Pettenkofer-Schwellen).
  Umsetzung wahlweise Chart.js-Annotation-Plugin oder zwei zusätzliche
  Datasets als gefüllte Bereiche – Entscheidung beim Implementieren

### CO₂-Ampel

* Schema: **Pettenkofer**
  * < 1000 ppm: gut (grün)
  * 1000–1400: mäßig (gelb)
  * > 1400: schlecht (rot)
* Schwellen als Konstanten im Helper, **nicht in der yml** konfigurierbar
* Helper (`app/helpers/sensors_helper.rb`):
  * `co2_level(ppm)` → `:good | :warn | :bad`
  * `co2_icon_path(level)` → Pfad auf eines der drei Filz-PNGs
* Assets: `app/assets/images/co2_good.png`, `co2_warn.png`, `co2_bad.png`
  (vom User bereitgestellt – ganze Ampeln, vertikal/Hochformat)
* Darstellung: ein PNG pro Indoor-Card, rechts neben den Messwerten,
  feste Höhe (~72 px), Breite proportional (`object-fit: contain`)

### Batterie-Anzeige

* Klein in jeder Card (oben rechts oder neben dem Namen)
* Globale Warnung im Tab-Header, wenn ein Sensor < 20 %
  (für Outdoor heißt das praktisch: Sprung 60→20 löst die Warnung aus)

### Styling

Wiederverwendung der bestehenden Card-/Sektion-Styles aus dem Wetter-Tab. Neue
Klassen unter `app/assets/stylesheets/sensors.css`. Keine zusätzlichen
Frontend-Libraries.

## Wetter-Tab Anpassung (`/weather`)

* `WeatherController#index` holt zusätzlich die letzte `SensorReading` mit
  `device_id` aus der Liste der `outdoor_meter`-Sensoren
* Im Partial `_current.html.erb` wird die "aktuelle Temperatur" aus der
  Sensor-Lesung gezogen, **wenn vorhanden und nicht älter als 30 Min**; sonst
  Fallback auf Brightsky
* Subtiler Quell-Hinweis im UI: kleines Label "eigener Sensor" bzw. "DWD"
  hinter dem Wert
* Keine sonstigen Änderungen am Wetter-Tab (Wind, Bewölkung, Vorhersage bleiben
  Brightsky)

## Header / Navigation

`app/views/layouts/application.html.erb`: neuer Nav-Link "Sensoren" zwischen
"Wetter" und Ende.

## Aus dem Scope (V1)

* Historische Daten vor V1-Start – Verlauf wird ab Tag 1 selbst aufgebaut,
  kein Import aus der SwitchBot-App-Cloud
* Daten-Retention / Aggregation – alles bleibt in `sensor_readings`, keine
  5-Min-/Tages-Rollups
* Webhooks – nur Polling, keine Push-Events
* BLE-Fallback – Cloud-Ausfall → Lücke im Chart, kein Bluetooth-Direktauslesen
* Sensoren in den Berichten (`reports`) – kein Crossover zu Energiekosten
* Schwellen-Konfiguration in der yml – Pettenkofer-Werte als Konstanten
* Mehrere SwitchBot-Accounts – ein Token/Secret-Paar
* UI-Auswahl Zeitraum – Charts zeigen fix 24 h
* Push-Benachrichtigungen bei kritischem CO₂ – nur visuelle Ampel
* Konfigurierbares Poll-Intervall – fest 15 min
* Heatmap / Tag-Nacht-Vergleich / Schwellen-Analytics – V2+

## Tests

Analog zur bestehenden Test-Struktur:

* `test/lib/switch_bot_client_test.rb` – HMAC-Signatur, Response-Parsing für
  beide Gerätetypen, Fehlerfälle (Timeout, non-200, malformed)
* `test/jobs/sensor_poll_job_test.rb` – Persistenz, Sensor-Isolation bei
  Fehlern, kein Job-Fail bei Einzelsensor-Ausfall, Skip wenn keine Konfig
* `test/models/sensor_reading_test.rb` – `latest_per_device`-Scope
* `test/controllers/sensors_controller_test.rb` – `index` rendert mit/ohne
  Daten, `series` JSON-Format
* `test/controllers/weather_controller_test.rb` – Erweiterung: Außentemp aus
  Sensor wenn vorhanden, Fallback auf Brightsky bei Älter-als-30-Min
* `test/lib/config_loader_test.rb` – neue `switchbot:` und `sensors:` Blöcke,
  Plug-`room`-Feld

HTTP wird in den Tests gestubbed (`WebMock` oder `Faraday::Adapter::Test`,
je nachdem was im Projekt heute genutzt wird).

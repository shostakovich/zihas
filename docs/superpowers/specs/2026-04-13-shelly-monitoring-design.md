# ZiWoAS — Shelly-Monitoring (Balkonkraftwerk + Verbraucher)

**Status:** Design approved, ready for implementation plan
**Date:** 2026-04-13
**Scope:** Erstes Feature von ZiWoAS (Zipfelmaus-Wohnungs-Automatisierungs-system).

## Zielbild

Ein Dashboard, das zeigt:

- **Live-Leistung** des Balkonkraftwerks (BKW) und der gemessenen Verbraucher
- **Heutige Kennzahlen** — erzeugte kWh, geschätzte Ersparnis in €, aktueller Gesamtverbrauch
- **Verlauf-Graph** für heute (Leistung über Zeit, 1–5 min Auflösung)
- **Historisches Balkendiagramm** (Tagessummen, beliebig weit zurück)
- **Steckdosen-Status** inkl. Offline-Anzeige

Läuft als Docker-Container im Mini-Rack. Externe Erreichbarkeit wird durch Pangolin (Reverse-Proxy mit Auth) davor gelöst — die App selbst spricht Plain HTTP ohne eigene Auth.

## Non-Goals

- Keine Steuerung der Steckdosen (kein An-/Ausschalten von Verbrauchern)
- Keine Auth / User-Management in der App selbst
- Kein Multi-User-Setup
- Keine Unterstützung für Gen1-Shellies (nur Gen2+ mit RPC-API)
- Keine Feed-in-Tarif-Abrechnung (Ersparnis = Produktion × Preis, simple Annahme)
- Keine historische Strompreis-Verwaltung (nur aktueller Preis aus Config gilt rückwirkend)

## Architektur

Ein Ruby-Prozess, ein SQLite-File, ein Docker-Container. Drei Workloads im selben Prozess, kein externes Scheduling, keine Queue.

```
┌──────────────────────────────────────────────────────────┐
│  Docker Container (ruby:4.0-slim)                        │
│                                                          │
│   ┌─────────────────┐      ┌─────────────────────┐       │
│   │  Poller Thread  │─────▶│                     │       │
│   │  (5s tick)      │      │   SQLite DB         │       │
│   │  Net::HTTP      │      │   /data/ziwoas.db   │       │
│   └─────────────────┘      │                     │       │
│                            └─────────▲───────────┘       │
│   ┌─────────────────┐                │                   │
│   │ Aggregator      │────────────────┤                   │
│   │ Thread          │                │                   │
│   │ (nightly 03:15) │                │                   │
│   └─────────────────┘                │                   │
│                                      │                   │
│   ┌─────────────────┐                │                   │
│   │  Sinatra / Puma │────────────────┘                   │
│   │  Port 4567      │                                    │
│   │  - ERB Views    │      HTMX (vendored .js)           │
│   │  - JSON API     │      Chart.js (vendored .js)       │
│   └────────┬────────┘                                    │
└────────────┼─────────────────────────────────────────────┘
             │
             ▼
      Browser (im WLAN oder via Pangolin)
             │
             ▼
     Shellys @ 192.168.1.x
       GET /rpc/Switch.GetStatus?id=0
```

### Komponenten

1. **Poller** — eigener Thread, der alle 5 s durch die konfigurierten Plugs loopt und `apower` + `aenergy.total` via Shelly-RPC-API holt.
2. **CircuitBreaker** — in-memory State-Machine pro Plug, verhindert Log-Spam und reduziert Tick-Latenz bei dauerhaft offline Plugs.
3. **Aggregator** — eigener Thread, läuft nachts (03:15 lokal), erzeugt 5-Minuten-Aggregate und Tagessummen, purged alte Rohdaten, fährt das DB-Backup.
4. **Webserver (Sinatra/Puma)** — liefert HTML-Dashboard (ERB) und JSON-Endpoints für HTMX-Updates und Chart.js.
5. **Config-Loader** — liest `config/ziwoas.yml` beim Start, validiert streng, Abbruch bei fehlerhafter Konfiguration.

## Tech-Stack

- **Ruby 4.0.x** (Base-Image `ruby:4.0-slim`)
- **Sinatra** — minimales Web-Framework
- **Sequel + sqlite3** — Datenzugriff
- **Puma** — Rack-Server
- **rackup** — Rack-CLI (für Ruby 4.x nötig)

Minimale Dependency-Liste, bewusst gehalten. Kein Rails, kein ActiveRecord, kein Redis, kein Sidekiq, keine externe Cron-Kette.

**Frontend:** Vanilla HTML + ERB + vendored **HTMX** + vendored **Chart.js**. Kein npm, kein Bundler, kein Build-Step. Die beiden JS-Files liegen als statische Assets in `public/`.

**Testing:** Minitest (stdlib), `rack-test`, `webmock`. Nur `test` Group, nicht im Prod-Image.

## Datenmodell

Alle Zeitstempel als **UTC Unix-Sekunden**. Konvertierung zu Lokalzeit passiert in den Views und beim Aggregieren der Tagessummen (mittels `TZ` aus Config).

```sql
-- Rohdaten, alle 5s pro Plug. Nur erfolgreiche Polls landen hier.
-- Gaps in der Zeitreihe = Plug war offline.
CREATE TABLE samples (
  plug_id     TEXT    NOT NULL,          -- logische ID aus Config, z.B. "bkw"
  ts          INTEGER NOT NULL,          -- UTC unix seconds
  apower_w    REAL    NOT NULL,          -- Momentanleistung in W
  aenergy_wh  REAL    NOT NULL,          -- kumulativer Zähler in Wh
  PRIMARY KEY (plug_id, ts)
);
CREATE INDEX idx_samples_ts ON samples(ts);

-- 5-Minuten-Aggregate, nachts gefüllt. Retention: forever.
CREATE TABLE samples_5min (
  plug_id         TEXT    NOT NULL,
  bucket_ts       INTEGER NOT NULL,      -- UTC start of 5-min bucket
  avg_power_w     REAL    NOT NULL,      -- Mittel der Momentanleistung
  energy_delta_wh REAL    NOT NULL,      -- Energie-Diff über den Bucket
  sample_count    INTEGER NOT NULL,      -- Quality-Info
  PRIMARY KEY (plug_id, bucket_ts)
);

-- Tagessummen, nachts gefüllt. Retention: forever.
CREATE TABLE daily_totals (
  plug_id    TEXT    NOT NULL,
  date       TEXT    NOT NULL,           -- "YYYY-MM-DD" in Local-TZ
  energy_wh  REAL    NOT NULL,           -- Tages-Energie-Delta
  PRIMARY KEY (plug_id, date)
);
```

**Entscheidungen:**

- `plug_id` ist ein stabiler Text-Slug aus Config (`"bkw"`, `"kuehlschrank"`), nicht an IP oder Hardware gebunden. Hardware-Tausch ändert die Historie nicht.
- Die Rolle (`producer` / `consumer`) steht nicht in der DB — nur im Config. Die DB speichert rohe Messwerte.
- Nur erfolgreiche Polls werden gespeichert. Eine separate Error-Tabelle würde kaum Mehrwert bringen; Logs reichen.
- `aenergy_wh` (Shelly-Zählerstand) ist der Schlüssel zur Tages-Energie: `energy_wh = MAX(aenergy_wh) − MIN(aenergy_wh)` pro Tag. Robust gegen einzelne fehlende Polls.

## Polling & Robustheit

### Poller-Loop

```
loop:
  start_time = now()
  for each plug in config:
    wenn breaker(plug).skip?(now()): weiter
    try:
      response = http_get(shelly_url, timeout=2s)
      insert_sample(plug_id, ts, apower, aenergy_total)
      breaker(plug).record_success()
    except (Net::OpenTimeout | Net::ReadTimeout | Errno::ECONNREFUSED
          | Errno::EHOSTUNREACH | JSON::ParserError | HTTPError):
      breaker(plug).record_failure()
      log.warn "plug #{id} poll failed: #{reason}"   # nur bei State-Change
  sleep_until(start_time + 5s)
```

**Regeln:**

- **Per-Plug-Timeout: 2 s** (nicht 5), damit ein hängender Plug andere nicht zu sehr bremst.
- Nur **benannte Exceptions** fangen — Programmierfehler sollen krachen und im Log sichtbar sein, nicht still verschluckt werden.
- **Kein exponential backoff** — jeder Tick ist ein Versuch (modulo Circuit Breaker).
- Auch `response.code != 200` zählt als Failure (Shellies liefern beim Boot teils 503).

### Circuit Breaker (pro Plug, in-memory)

Einfache State-Machine:

- `:closed` — Normalbetrieb, jeder Tick pollt.
- `:open` — nach 3 aufeinanderfolgenden Fehlern. Poll wird geskippt, bis `now >= open_until` (initial `now + 30s`). Ein erfolgreicher Probe-Poll → zurück zu `:closed`.
- **Log-Zeilen nur bei State-Transitions** (`opening breaker`, `recovered`).

### Supervision

- **Aggregator-Thread-Crash** → Prozess beendet sich mit Exit-Code ≠ 0, Docker restartet den Container (einfacher als interne Restart-Logik).
- **SIGTERM-Handling** — Threads sauber beenden, `docker stop` blockiert nicht bis zum Kill.

### UI-Verhalten bei Offline-Plugs

- Plug-Karte zeigt `online` (grüner Dot + Wert) oder `offline (seit Xs)` (grauer Dot, reduzierte Opazität).
- „Offline" = letzter Sample älter als 10 s (zwei Poll-Intervalle) oder Breaker ist `:open`.

## Aggregator & Retention

Läuft einmal täglich um **03:15 Lokalzeit**:

```
for each day D where D < today and not fully in daily_totals:
  for each plug_id:
    # 5-min buckets
    INSERT OR REPLACE INTO samples_5min (...)
      SELECT plug_id,
             (ts / 300) * 300 AS bucket_ts,
             AVG(apower_w),
             MAX(aenergy_wh) - MIN(aenergy_wh),
             COUNT(*)
        FROM samples
       WHERE plug_id = ? AND ts >= D_start AND ts < D_end
       GROUP BY bucket_ts;

    # daily total
    INSERT OR REPLACE INTO daily_totals (...)
      SELECT plug_id, 'YYYY-MM-DD',
             MAX(aenergy_wh) - MIN(aenergy_wh)
        FROM samples WHERE ...;

DELETE FROM samples WHERE ts < now() - 7 * 86400;

# Optional (einmal pro Woche): VACUUM;
```

**Idempotent** — wenn der Container mehrere Tage down war, werden alle offenen Tage rückwirkend verarbeitet. `INSERT OR REPLACE` macht wiederholte Läufe ungefährlich.

**Warum 03:15 statt 00:00:** Wenn der Container nachts restartet, haben wir etwas Puffer, bevor der Tag „abgeschlossen" wird.

## HTTP-API (Sinatra)

| Route | Purpose |
|---|---|
| `GET /` | HTML-Dashboard (ERB-Layout, Hero-Layout A) |
| `GET /api/live` | JSON: aktueller Wert pro Plug (`apower_w`, `online`, `last_seen_ts`) |
| `GET /api/today` | JSON: Zeitreihe Leistung heute (1-min-Buckets aus `samples`, on-the-fly) |
| `GET /api/history?days=14` | JSON: `daily_totals` der letzten N Tage |
| `GET /api/today/summary` | JSON: `produced_wh_today`, `consumed_wh_today`, `savings_eur_today` |
| `GET /htmx.min.js`, `GET /chart.min.js`, `GET /app.css` | Statische Assets (Sinatra serviert `public/` direkt am Root) |

HTMX pollt `/api/live` und `/api/today/summary` alle 5 s; Chart.js holt `/api/today` alle 60 s und `/api/history` beim Laden.

## UI-Layout (Hero, Layout A)

Eine Spalte, vertikal scrollbar, mobile-first. Reihenfolge:

1. **Hero-Tile**: BKW-Leistung groß (z.B. `342 W`) — zentral, prominent, gelber Akzent.
2. **Drei kompakte Tiles**: „Heute erzeugt" · „Heute gespart" · „Verbrauch jetzt"
3. **Heute — Leistung über Zeit** (Chart.js Line/Area, 1-min-Buckets)
4. **Steckdosen** (horizontal scrollable Chips mit Live-Wert und Status-Dot)
5. **Letzte 14 Tage — Tagesertrag** (Chart.js Bar)

UI-Sprache: **Deutsch**. Code/Variablen: Englisch.

## Config

**`config/ziwoas.yml`** — Wird beim Start geladen und streng validiert. Fehler = Exit 1.

```yaml
electricity_price_eur_per_kwh: 0.32
timezone: Europe/Berlin

poll:
  interval_seconds: 5
  timeout_seconds: 2
  circuit_breaker_threshold: 3
  circuit_breaker_probe_seconds: 30

aggregator:
  run_at: "03:15"
  raw_retention_days: 7

plugs:
  - id: bkw
    name: Balkonkraftwerk
    role: producer
    host: 192.168.1.192

  - id: kuehlschrank
    name: Kühlschrank
    role: consumer
    host: 192.168.1.201
```

**Validierungsregeln:**

- Mindestens ein Plug mit `role: producer` (sonst macht das Dashboard keinen Sinn).
- `plug.id` unique, nur `[a-z0-9_]+`.
- `plug.role` ∈ `{producer, consumer}`.
- `plug.host` parsebarer Host/IP.
- `timezone` muss in Ruby's TZInfo auflösbar sein.
- Alle numerischen Werte > 0.

## Deployment

### Dockerfile

```dockerfile
FROM ruby:4.0-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libsqlite3-dev tzdata \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config set --local deployment 'true' \
 && bundle config set --local without 'development test' \
 && bundle install --jobs 4

COPY . .

VOLUME ["/data"]
ENV DATABASE_PATH=/data/ziwoas.db
ENV CONFIG_PATH=/app/config/ziwoas.yml
ENV TZ=Europe/Berlin

EXPOSE 4567
CMD ["bundle", "exec", "puma", "-p", "4567"]
```

### docker-compose.yml

```yaml
services:
  ziwoas:
    image: ziwoas:latest
    build: .
    restart: unless-stopped
    ports:
      - "4567:4567"
    volumes:
      - ./data:/data
      - ./config/ziwoas.yml:/app/config/ziwoas.yml:ro
```

## Backup

Der Aggregator-Thread führt nach dem nächtlichen Aggregations-Lauf (gegen 03:30) ein SQLite-internes Backup durch:

```
sqlite3 /data/ziwoas.db ".backup /data/backup/ziwoas-YYYY-MM-DD.db"
```

- Behält die letzten **7 täglichen Snapshots** in `/data/backup/`, löscht ältere.
- Konsistent auch während Writes (WAL-kompatibel, via SQLite `.backup`).
- Das `./data/`-Verzeichnis kann offsite per `restic`/Borg/`rsync` zum NAS gesichert werden — das übernimmt die bestehende Host-Backup-Kette.

Litestream oder ähnliche Point-in-Time-Replikation ist **explizit nicht Teil des Scopes** (YAGNI für ein Home-Projekt).

## Testing-Strategie

Pragmatisch, nicht erschöpfend.

**Unit-Tests** (Minitest + WebMock):

- `ShellyClient` — Parsing der Response, Mapping der erwarteten Exceptions
- `CircuitBreaker` — State-Transitions mit mock clock
- `Aggregator` — 5-min-Buckets und daily-deltas gegen deterministische In-Memory-SQLite
- `SavingsCalculator` — kWh × €/kWh
- `ConfigLoader` — Validierung schlägt bei allen dokumentierten Regeln fehl

**Ein Integration-Test** (Rack-Test):

- App bootet mit temp. SQLite + gemockter Shelly (WebMock)
- `GET /` rendert
- `GET /api/live` liefert erwartetes JSON
- `GET /api/today/summary` berechnet korrekt

**Kein Frontend-Test.** HTMX-+-Chart.js-Frontend ist klein genug, dass ein manueller Smoke-Check im Browser reicht.

## Offene Fragen / spätere Iterationen

Bewusst nicht in Scope, aber kandidat für spätere Features:

- Steuerung (Verbraucher an/aus bei Überschuss)
- Historische Strompreise (zeitabhängige Tarife)
- Feed-in-Tarif (was nicht selbst verbraucht wird → Einspeise-Vergütung)
- Benachrichtigungen (z.B. „Plug X seit 24h offline")
- Export (CSV / InfluxDB-Bridge / Prometheus-Scraper)

## Projekt-Struktur (vorläufig)

```
zihas/
├── Dockerfile
├── docker-compose.yml
├── Gemfile
├── config.ru
├── config/
│   └── ziwoas.yml
├── lib/
│   ├── ziwoas.rb              # top-level app builder
│   ├── config_loader.rb
│   ├── shelly_client.rb
│   ├── circuit_breaker.rb
│   ├── poller.rb
│   ├── aggregator.rb
│   ├── savings_calculator.rb
│   └── db.rb                  # Sequel setup + migrations
├── app/
│   ├── web.rb                 # Sinatra app
│   └── views/                 # .erb
├── public/
│   ├── htmx.min.js
│   ├── chart.min.js
│   └── app.css
├── test/
│   ├── test_helper.rb
│   └── ... (one file per lib)
└── docs/superpowers/specs/
    └── 2026-04-13-shelly-monitoring-design.md   # this file
```

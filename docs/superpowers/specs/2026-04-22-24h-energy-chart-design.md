# Design: 24h-Fenster + Gesamtenergie-Balkendiagramm

## Übersicht

Zwei Änderungen am Dashboard:
1. Den bestehenden Leistungs-Chart auf ein rollendes 24h-Fenster umstellen
2. Neuen Gesamtenergie-Chart (gruppierte Balken, stündlich) hinzufügen

## Backend

### `/api/today` — Zeitfenster ändern

Aktuell: `today_bounds_utc` → Mitternacht bis Mitternacht (Tagesbeginn lokal)  
Neu: rollendes Fenster `now - 86400` bis `now` (UTC-Timestamps)

Der Helper `today_bounds_utc` wird nicht mehr benötigt für diesen Endpunkt; stattdessen direkt `now = Time.now.to_i` und `start_ts = now - 86_400`.

`/api/today/summary` bleibt unverändert (nutzt weiterhin `today_bounds_utc` für die "Heute"-Kacheln).

## Frontend

### Labels

| Alt | Neu |
|-----|-----|
| Heute — Leistung über Zeit | Leistung — Letzte 24 h |
| (neu) | Gesamtenergie — Letzte 24 h |

### Neuer Chart: Gesamtenergie — Letzte 24 h

**Canvas:** `#energy-chart`

**Datenquelle:** Selber `/api/today`-Response wie der Leistungs-Chart (kein zweiter Fetch).

**JS-Aggregation in `loadEnergyChart(data)`:**
- Für jeden Datenpunkt (Minute): `energy_wh = avg_power_w * (1/60)`
- Stunden-Bucket: `Math.floor(ts_ms / 3_600_000) * 3_600_000`
- Erzeugt: Summe aller Punkte mit `role === "producer"` (Absolutwert)
- Verbraucht: Summe aller Punkte mit `role === "consumer"`
- Ergebnis: 24 Stunden-Buckets à { label: "HH:00", produced_kwh, consumed_kwh }

**Chart.js-Konfiguration:**
- Typ: `bar`
- Datasets: `[{ label: "Erzeugt", backgroundColor: "#f59f00" }, { label: "Verbraucht", backgroundColor: "#3b82f6" }]`
- X-Achse: kategorisch, Labels "HH:00"
- Y-Achse: `beginAtZero: true`, Titel "kWh"
- Legend: `position: "bottom"`
- Animation: `false`

### Laden und Refresh

`loadTodayChart()` und `loadEnergyChart()` teilen sich einen einzigen `/api/today`-Fetch.  
Refresh-Intervall: 60 s (gleich wie heute).

## Nicht im Scope

- `/api/today/summary` bleibt "heute ab Mitternacht"
- History-Chart bleibt unverändert
- Keine neuen API-Endpunkte

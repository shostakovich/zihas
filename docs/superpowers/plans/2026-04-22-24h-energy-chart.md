# 24h Rolling Window + Gesamtenergie Chart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Beide Chart-Zeitfenster auf rolling 24h umstellen und einen neuen gruppierten Balkendiagramm für stündliche kWh (erzeugt vs. verbraucht) hinzufügen.

**Architecture:** Backend-Endpunkt `/api/today` liefert künftig die letzten 86 400 Sekunden statt Kalender-Mitternacht. Im Frontend teilen sich Leistungs- und Energie-Chart einen einzigen Fetch; der Energie-Chart aggregiert die Minuten-Datenpunkte in JS zu stündlichen kWh-Buckets.

**Tech Stack:** Ruby/Sinatra (backend), Chart.js 4, HTMX, ERB (frontend)

---

## File Map

| Datei | Änderung |
|-------|----------|
| `app/web.rb` | `/api/today` Zeitfenster: `today_bounds_utc` → `now - 86_400..now` |
| `app/views/dashboard.erb` | Label umbenennen, Energie-Chart-HTML + JS hinzufügen |
| `test/test_web.rb` | `test_api_today_*` Fixture auf `now - 3600` umstellen |

---

### Task 1: Backend — `/api/today` auf rolling 24h umstellen

**Files:**
- Modify: `app/web.rb:71-87`
- Test: `test/test_web.rb:76-94`

- [ ] **Step 1: Test aktualisieren — Fixture auf `now - 3600`**

In `test/test_web.rb` die Methode `test_api_today_returns_per_minute_series_per_plug` ersetzen:

```ruby
def test_api_today_returns_per_minute_series_per_plug
  now = Time.now.to_i
  Web.settings.db[:samples].insert(plug_id: "bkw", ts: now - 3600,
                                   apower_w: 200.0, aenergy_wh: 100.0)
  Web.settings.db[:samples].insert(plug_id: "bkw", ts: now - 3540,
                                   apower_w: 300.0, aenergy_wh: 110.0)

  get "/api/today"
  assert_equal 200, last_response.status
  data = JSON.parse(last_response.body)
  bkw  = data["series"].find { |s| s["plug_id"] == "bkw" }
  refute_nil bkw
  assert bkw["points"].length >= 1
  point = bkw["points"].first
  assert point.key?("ts")
  assert point.key?("avg_power_w")
end
```

- [ ] **Step 2: Test ausführen — erwartet PASS (Mitternacht liegt noch innerhalb 24h)**

```bash
ruby test/test_web.rb -n test_api_today_returns_per_minute_series_per_plug
```

Expected: 1 run, 0 failures

- [ ] **Step 3: `/api/today` Route in `app/web.rb` umstellen**

Aktuelle Zeilen 71-73:
```ruby
get "/api/today" do
  start_ts, end_ts, _today = today_bounds_utc
```

Ersetzen durch:
```ruby
get "/api/today" do
  end_ts   = Time.now.to_i
  start_ts = end_ts - 86_400
```

Die restliche Route (Zeilen 74-87) bleibt unverändert.

- [ ] **Step 4: Alle Web-Tests ausführen**

```bash
ruby test/test_web.rb
```

Expected: 6 runs, 0 failures, 0 errors

- [ ] **Step 5: Commit**

```bash
git add app/web.rb test/test_web.rb
git commit -m "feat: change /api/today to rolling 24h window"
```

---

### Task 2: Frontend — Label umbenennen

**Files:**
- Modify: `app/views/dashboard.erb:42`

- [ ] **Step 1: Label in `dashboard.erb` ändern**

Zeile 42 — alt:
```html
<div class="section-label">Heute — Leistung über Zeit</div>
```

Neu:
```html
<div class="section-label">Leistung — Letzte 24 h</div>
```

- [ ] **Step 2: Smoke-Test ausführen**

```bash
ruby test/test_web.rb -n test_root_serves_dashboard_html
```

Expected: 1 run, 0 failures

- [ ] **Step 3: Commit**

```bash
git add app/views/dashboard.erb
git commit -m "feat: rename power chart label to 'Letzte 24 h'"
```

---

### Task 3: Frontend — Energie-Chart hinzufügen

**Files:**
- Modify: `app/views/dashboard.erb`

- [ ] **Step 1: HTML-Abschnitt nach dem History-Chart einfügen**

Nach Zeile 51 (`</div>` des history-chart card) einfügen:

```html
<!-- Energy chart -->
<div class="section-label">Gesamtenergie — Letzte 24 h</div>
<div class="chart-card">
  <canvas id="energy-chart"></canvas>
</div>
```

- [ ] **Step 2: JS — gemeinsamen Fetch einführen und `loadEnergyChart` ergänzen**

Den bestehenden `<script>`-Block am Ende von `dashboard.erb` anpassen.

**a) Variable für Energie-Chart hinzufügen** — bei der Zeile `let todayChart, historyChart;`:

```javascript
let todayChart, historyChart, energyChart;
```

**b) `loadTodayChart()` in zwei Funktionen aufteilen:**  
`loadTodayChart()` wird zu einer reinen Render-Funktion, ein neuer Wrapper holt die Daten und ruft beide Charts auf.

Ersetze die komplette `loadTodayChart`-Funktion (Zeilen 114–164) durch:

```javascript
function renderTodayChart(data) {
  let consumerIdx = 0;
  const datasets = data.series.map(s => {
    const isProducer = s.role === "producer";
    const dataset = {
      label: s.name,
      data: s.points.map(pt => ({ x: pt.ts * 1000, y: isProducer ? Math.abs(pt.avg_power_w) : pt.avg_power_w })),
      tension: 0.2,
      fill: isProducer,
      pointRadius: 0,
    };
    if (isProducer) {
      dataset.borderColor = "#f59f00";
      dataset.backgroundColor = "rgba(245,159,0,0.12)";
    } else {
      const color = CONSUMER_COLORS[consumerIdx++ % CONSUMER_COLORS.length];
      dataset.borderColor = color;
      dataset.backgroundColor = color;
    }
    return dataset;
  });
  if (todayChart) todayChart.destroy();
  todayChart = new Chart(document.getElementById("today-chart"), {
    type: "line",
    data: { datasets },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      scales: {
        x: {
          type: "linear",
          title: { display: true, text: "Uhrzeit" },
          ticks: {
            callback: (v) => {
              const d = new Date(v);
              return d.getHours().toString().padStart(2,"0") + ":" +
                     d.getMinutes().toString().padStart(2,"0");
            },
            stepSize: 3_600_000,
            maxTicksLimit: 9,
          },
        },
        y: { beginAtZero: true, title: { display: true, text: "Watt" } },
      },
      plugins: { legend: { position: "bottom" } },
      animation: false,
    },
  });
}

function renderEnergyChart(data) {
  const buckets = {};
  for (const series of data.series) {
    for (const pt of series.points) {
      const hourKey = Math.floor(pt.ts / 3600) * 3600;
      const wh = Math.abs(pt.avg_power_w) / 60;
      if (!buckets[hourKey]) buckets[hourKey] = { produced: 0, consumed: 0 };
      if (series.role === "producer") {
        buckets[hourKey].produced += wh;
      } else {
        buckets[hourKey].consumed += wh;
      }
    }
  }
  const sorted = Object.keys(buckets).map(Number).sort((a, b) => a - b);
  const labels = sorted.map(ts => {
    const d = new Date(ts * 1000);
    return d.getHours().toString().padStart(2, "0") + ":00";
  });
  const produced = sorted.map(ts => +(buckets[ts].produced / 1000).toFixed(3));
  const consumed = sorted.map(ts => +(buckets[ts].consumed / 1000).toFixed(3));
  if (energyChart) energyChart.destroy();
  energyChart = new Chart(document.getElementById("energy-chart"), {
    type: "bar",
    data: {
      labels,
      datasets: [
        { label: "Erzeugt",    data: produced, backgroundColor: "#f59f00" },
        { label: "Verbraucht", data: consumed,  backgroundColor: "#3b82f6" },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      scales: { y: { beginAtZero: true, title: { display: true, text: "kWh" } } },
      plugins: { legend: { position: "bottom" } },
      animation: false,
    },
  });
}

function loadTodayChart() {
  fetch("/api/today").then(r => r.json()).then(data => {
    renderTodayChart(data);
    renderEnergyChart(data);
  });
}
```

- [ ] **Step 3: `DOMContentLoaded`-Block prüfen**

Der Block ruft bereits `loadTodayChart()` auf — kein weiterer Aufruf für `loadEnergyChart` nötig, da der gemeinsame Fetch beide rendert. Sicherstellen dass der Block so aussieht:

```javascript
document.addEventListener("DOMContentLoaded", () => {
  loadTodayChart();
  loadHistoryChart();
  setInterval(loadTodayChart, 60_000);
  setInterval(loadHistoryChart, 3_600_000);
});
```

- [ ] **Step 4: Smoke-Test ausführen**

```bash
ruby test/test_web.rb
```

Expected: 6 runs, 0 failures, 0 errors

- [ ] **Step 5: Commit**

```bash
git add app/views/dashboard.erb
git commit -m "feat: add Gesamtenergie 24h grouped bar chart"
```

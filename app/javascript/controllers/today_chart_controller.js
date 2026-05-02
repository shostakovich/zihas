import { Controller } from "@hotwired/stimulus"
import "chart.js"
import consumer from "channels/consumer"

// Connects to data-controller="today-chart"
// Manages the 24h power line chart and the 24h energy bar chart.
// - Initial data loaded via HTTP on connect and on visibility restore after gap.
// - Incremental updates via ActionCable:
//     same bucket_ts → update last point in place
//     next bucket_ts (+60s) → push new point
//     gap > 120s        → full reload from /api/today
export default class extends Controller {
  static targets = ["powerCanvas", "energyCanvas"]

  static values = {
    gapThresholdMs: { type: Number, default: 120_000 },
    refreshInterval: { type: Number, default: 3_600_000 }, // history reload (1h)
  }

  connect() {
    this.powerChart  = null
    this.energyChart = null
    // plug_id → Chart.js dataset index (populated on chart build)
    this.datasetIndex = {}

    this.loadCharts()

    this.subscription = consumer.subscriptions.create("DashboardChannel", {
      received: (data) => this.handleReading(data),
    })

    // Reload charts once an hour to pick up any corrected data
    this.refreshTimer = setInterval(() => this.loadCharts(), this.refreshIntervalValue)

    // Reload when tab becomes visible again (laptop open after sleep, etc.)
    this._onVisibilityChange = () => {
      if (document.visibilityState === "visible") this.loadCharts()
    }
    document.addEventListener("visibilitychange", this._onVisibilityChange)

    // bfcache restore (Safari back/forward)
    this._onPageShow = (e) => { if (e.persisted) this.loadCharts() }
    window.addEventListener("pageshow", this._onPageShow)
  }

  disconnect() {
    this.subscription?.unsubscribe()
    clearInterval(this.refreshTimer)
    document.removeEventListener("visibilitychange", this._onVisibilityChange)
    window.removeEventListener("pageshow", this._onPageShow)
    this.powerChart?.destroy()
    this.energyChart?.destroy()
  }

  // --- ActionCable handler ---

  handleReading(data) {
    if (!this.powerChart) return
    if (!Array.isArray(data.plugs)) return

    let changed = false
    for (const plug of data.plugs) {
      const result = this._updatePowerChart(plug)
      if (result === "reload") return
      changed ||= result
    }

    if (changed) {
      this._replaceTotalConsumptionDataset()
      this.powerChart.update("none") // "none" = no animation, instant
    }
  }

  _updatePowerChart(data) {
    const idx = this.datasetIndex[data.plug_id]
    if (idx === undefined) return false

    const dataset = this.powerChart.data.datasets[idx]
    const last    = dataset.data.at(-1)
    const newX    = data.bucket_ts * 1000

    const y = data.role === "producer" ? Math.abs(data.avg_power_w) : data.avg_power_w

    if (last) {
      const gap = newX - last.x
      if (gap > this.gapThresholdMsValue) {
        // Too big a jump — data was missed while tab/laptop was sleeping.
        // Full reload gives us the correct picture.
        this.loadCharts()
        return "reload"
      } else if (last.x === newX) {
        // Same bucket: update running average in place
        last.y = y
      } else {
        // Next bucket: append
        dataset.data.push({ x: newX, y })
        // Drop points older than 25h to keep chart lean
        const cutoff = Date.now() - 25 * 3_600_000
        while (dataset.data.length > 0 && dataset.data[0].x < cutoff) {
          dataset.data.shift()
        }
      }
    } else {
      dataset.data.push({ x: newX, y })
    }

    return true
  }

  // --- Full chart load via HTTP ---

  async loadCharts() {
    try {
      const response = await fetch("/api/today")
      if (!response.ok) return
      const data = await response.json()
      this._buildPowerChart(data)
      this._buildEnergyChart(data)
    } catch (e) {
      console.error("loadCharts failed:", e)
    }
  }

  // --- Chart builders ---

  _buildPowerChart(data) {
    this.datasetIndex = {}
    const CONSUMER_COLORS = [
      "#3b82f6", "#10b981", "#8b5cf6", "#ef4444", "#06b6d4",
      "#ec4899", "#84cc16", "#6366f1", "#14b8a6", "#f43f5e",
    ]
    let consumerIdx = 0

    const datasets = data.series.map((s, i) => {
      this.datasetIndex[s.plug_id] = i
      const isProducer = s.role === "producer"
      const dataset = {
        label: s.name,
        data: s.points.map(pt => ({
          x: pt.ts * 1000,
          y: isProducer ? Math.abs(pt.avg_power_w) : pt.avg_power_w,
        })),
        role: s.role,
        tension: 0.2,
        fill: isProducer,
        pointRadius: 0,
      }
      if (isProducer) {
        dataset.borderColor      = "#f59f00"
        dataset.backgroundColor  = "rgba(245,159,0,0.12)"
      } else {
        const color = CONSUMER_COLORS[consumerIdx++ % CONSUMER_COLORS.length]
        dataset.borderColor     = color
        dataset.backgroundColor = color
      }
      return dataset
    })
    const totalConsumption = this._totalPowerConsumptionDataset(datasets)
    if (totalConsumption) datasets.push(totalConsumption)

    this.powerChart?.destroy()
    if (!this.hasPowerCanvasTarget) return
    this.powerChart = new Chart(this.powerCanvasTarget, {
      type: "line",
      data: { datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: {
          x: {
            type: "linear",
            min: Date.now() - 86_400_000,
            max: Date.now(),
            title: { display: true, text: "Uhrzeit" },
            ticks: {
              callback: (v) => {
                const d = new Date(v)
                return d.getHours().toString().padStart(2, "0") + ":" +
                       d.getMinutes().toString().padStart(2, "0")
              },
              stepSize: 3 * 3_600_000,
            },
          },
          y: { beginAtZero: true, title: { display: true, text: "Watt" } },
        },
        plugins: { legend: { position: "bottom" } },
        animation: false,
      },
    })
  }

  _buildEnergyChart(data) {
    const CONSUMER_COLORS = [
      "#3b82f6", "#10b981", "#8b5cf6", "#ef4444", "#06b6d4",
      "#ec4899", "#84cc16", "#6366f1", "#14b8a6", "#f43f5e",
    ]
    const consumers = data.series.filter((series) => series.role === "consumer")
    const buckets = {}
    for (const series of data.series) {
      for (const pt of series.points) {
        const hourKey = Math.floor(pt.ts / 3600) * 3600
        const wh = Math.abs(pt.avg_power_w) / 60
        if (!buckets[hourKey]) buckets[hourKey] = { produced: 0, consumers: {} }
        if (series.role === "producer") {
          buckets[hourKey].produced += wh
        } else {
          buckets[hourKey].consumers[series.plug_id] ||= 0
          buckets[hourKey].consumers[series.plug_id] += wh
        }
      }
    }
    const sorted   = Object.keys(buckets).map(Number).sort((a, b) => a - b)
    const labels   = sorted.map(ts => new Date(ts * 1000).getHours().toString().padStart(2, "0") + ":00")
    const produced = sorted.map(ts => +(buckets[ts].produced / 1000).toFixed(3))
    const consumed = sorted.map(ts => {
      const wh = Object.values(buckets[ts].consumers).reduce((sum, value) => sum + value, 0)
      return +(wh / 1000).toFixed(3)
    })
    const consumerDatasets = consumers.map((series, index) => ({
      label: series.name,
      data: sorted.map(ts => +((buckets[ts].consumers[series.plug_id] || 0) / 1000).toFixed(3)),
      backgroundColor: CONSUMER_COLORS[index % CONSUMER_COLORS.length],
      stack: "consumed",
    }))

    this.energyChart?.destroy()
    if (!this.hasEnergyCanvasTarget) return
    this.energyChart = new Chart(this.energyCanvasTarget, {
      type: "bar",
      data: {
        labels,
        datasets: [
          { label: "Erzeugt", data: produced, backgroundColor: "#f59f00", stack: "produced" },
          ...consumerDatasets,
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: {
          x: { stacked: true },
          y: { stacked: true, beginAtZero: true, title: { display: true, text: "kWh" } },
        },
        plugins: { legend: { position: "bottom" } },
        animation: false,
      },
    })
  }

  _replaceTotalConsumptionDataset() {
    if (!this.powerChart) return

    const existing    = this.powerChart.data.datasets.find((d) => d.isTotalConsumption)
    const others      = this.powerChart.data.datasets.filter((d) => !d.isTotalConsumption)
    const newDataset  = this._totalPowerConsumptionDataset(others)

    if (existing && newDataset) {
      existing.data = newDataset.data // update in place — preserves Chart.js hidden state
    } else if (!existing && newDataset) {
      this.powerChart.data.datasets.push(newDataset)
    } else if (existing && !newDataset) {
      const idx = this.powerChart.data.datasets.indexOf(existing)
      this.powerChart.data.datasets.splice(idx, 1)
    }
  }

  _totalPowerConsumptionDataset(datasets) {
    const consumers = datasets.filter((dataset) => dataset.role === "consumer")
    if (consumers.length === 0) return null

    const pointsByTs = new Map()
    for (const dataset of consumers) {
      for (const point of dataset.data) {
        pointsByTs.set(point.x, (pointsByTs.get(point.x) || 0) + point.y)
      }
    }

    return {
      label: "Gesamtverbrauch",
      data: Array.from(pointsByTs.entries())
        .sort(([a], [b]) => a - b)
        .map(([x, y]) => ({ x, y })),
      borderColor: "#1d4ed8",
      backgroundColor: "rgba(59, 130, 246, 0.14)",
      fill: true,
      pointRadius: 0,
      tension: 0.2,
      role: "consumer_total",
      isTotalConsumption: true,
    }
  }
}

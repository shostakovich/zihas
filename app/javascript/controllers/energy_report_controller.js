import { Controller } from "@hotwired/stimulus"
import "chart.js"

// Connects to data-controller="energy-report"
// Rails renders the report data; this controller only turns embedded JSON into charts.
export default class extends Controller {
  static targets = ["payload", "dailyCanvas", "ratiosCanvas", "detailCanvas"]

  connect() {
    this.dailyChart = null
    this.ratiosChart = null
    this.detailChart = null
    this.payload = this._readPayload()
    this._buildDailyChart()
    this._buildRatiosChart()
    this._buildDetailChart()
  }

  disconnect() {
    this.dailyChart?.destroy()
    this.ratiosChart?.destroy()
    this.detailChart?.destroy()
  }

  _readPayload() {
    if (!this.hasPayloadTarget) return { daily: {}, detail: {} }

    try {
      return JSON.parse(this.payloadTarget.textContent)
    } catch (error) {
      console.error("energy report payload parse failed:", error)
      return { daily: {}, detail: {} }
    }
  }

  _buildDailyChart() {
    if (!this.hasDailyCanvasTarget) return

    const daily = this.payload.daily || {}
    const labels = daily.labels || []
    const consumerDatasets = this._consumerBarDatasets(daily.consumer_series || [])
    const consumedDatasets = consumerDatasets.length > 0 ? consumerDatasets : [
      {
        label: "Verbrauch",
        data: daily.consumed_kwh || [],
        backgroundColor: "#3b82f6",
        stack: "consumed",
      },
    ]

    this.dailyChart = this._replaceChart(this.dailyCanvasTarget, {
      type: "bar",
      data: {
        labels,
        datasets: [
          {
            label: "Ertrag",
            data: daily.produced_kwh || [],
            backgroundColor: "#f59f00",
            stack: "produced",
          },
          ...consumedDatasets,
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

  _buildRatiosChart() {
    if (!this.hasRatiosCanvasTarget) return

    const daily = this.payload.daily || {}
    const ratios = daily.ratios || []
    const labels = ratios.map((r) => {
      const [, m, d] = r.date.split("-")
      return `${d}.${m}.`
    })
    const autarky = ratios.map((r) => (r.autarky_pct === null ? null : r.autarky_pct))
    const selfCons = ratios.map((r) => (r.self_consumption_pct === null ? null : r.self_consumption_pct))

    this.ratiosChart = this._replaceChart(this.ratiosCanvasTarget, {
      type: "line",
      data: {
        labels,
        datasets: [
          {
            label: "Autarkie",
            data: autarky,
            borderColor: "#10b981",
            backgroundColor: "#10b981",
            spanGaps: false,
            fill: false,
            tension: 0.2,
            pointRadius: 3,
          },
          {
            label: "Eigenverbrauch",
            data: selfCons,
            borderColor: "#f59f00",
            backgroundColor: "#f59f00",
            spanGaps: false,
            fill: false,
            tension: 0.2,
            pointRadius: 3,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: {
          y: { min: 0, max: 100, title: { display: true, text: "%" } },
        },
        plugins: { legend: { position: "bottom" } },
        animation: false,
      },
    })
  }

  _buildDetailChart() {
    if (!this.hasDetailCanvasTarget) return

    const detail = this.payload.detail || {}
    if (detail.chart_type === "bar") {
      this._buildDailyPowerBarChart(detail)
      return
    }

    this._buildPowerLineChart(detail)
  }

  _buildPowerLineChart(detail) {
    const labels = detail.labels || []
    const colors = ["#f59f00", "#3b82f6", "#10b981", "#8b5cf6", "#ef4444", "#06b6d4", "#ec4899"]

    const datasets = (detail.series || []).map((series, index) => {
      const color = series.role === "producer" ? "#f59f00" : colors[index % colors.length]
      return {
        label: series.name,
        data: series.data,
        borderColor: color,
        backgroundColor: color,
        fill: false,
        tension: 0.2,
        pointRadius: 0,
      }
    })
    const totalConsumption = this._totalConsumptionDataset(detail.series || [])
    if (totalConsumption) datasets.push(totalConsumption)

    this.detailChart = this._replaceChart(this.detailCanvasTarget, {
      type: "line",
      data: { labels, datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: {
          x: { ticks: { maxTicksLimit: 21, autoSkip: true } },
          y: { beginAtZero: true, title: { display: true, text: "Watt" } },
        },
        plugins: { legend: { position: "bottom" } },
        animation: false,
      },
    })
  }

  _buildDailyPowerBarChart(detail) {
    const labels = detail.labels || []
    const producerDatasets = (detail.series || [])
      .filter((series) => series.role === "producer")
      .map((series) => ({
        label: series.name,
        data: series.data || [],
        backgroundColor: "#f59f00",
        stack: "produced",
      }))
    const consumerDatasets = this._consumerBarDatasets(
      (detail.series || []).filter((series) => series.role === "consumer")
    )

    this.detailChart = this._replaceChart(this.detailCanvasTarget, {
      type: "bar",
      data: {
        labels,
        datasets: [
          ...producerDatasets,
          ...consumerDatasets,
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: {
          x: { stacked: true },
          y: { stacked: true, beginAtZero: true, title: { display: true, text: "Watt" } },
        },
        plugins: { legend: { position: "bottom" } },
        animation: false,
      },
    })
  }

  _replaceChart(canvas, config) {
    Chart.getChart(canvas)?.destroy()
    return new Chart(canvas, config)
  }

  _consumerBarDatasets(series) {
    const colors = ["#3b82f6", "#10b981", "#8b5cf6", "#ef4444", "#06b6d4", "#ec4899", "#84cc16", "#6366f1"]

    return series.map((row, index) => ({
      label: row.name,
      data: row.data || [],
      backgroundColor: colors[index % colors.length],
      stack: "consumed",
    }))
  }

  _totalConsumptionDataset(series) {
    const consumers = series.filter((row) => row.role === "consumer")
    if (consumers.length === 0) return null

    const length = Math.max(...consumers.map((row) => (row.data || []).length))
    const data = Array.from({ length }, (_, index) => {
      return consumers.reduce((sum, row) => sum + Number(row.data?.[index] || 0), 0)
    })

    return {
      label: "Gesamtverbrauch",
      data,
      borderColor: "#1d4ed8",
      backgroundColor: "rgba(59, 130, 246, 0.14)",
      fill: true,
      tension: 0.2,
      pointRadius: 0,
    }
  }
}

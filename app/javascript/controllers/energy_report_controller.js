import { Controller } from "@hotwired/stimulus"
import "chart.js"

// Connects to data-controller="energy-report"
// Renders bar/line charts plus an in-canvas weather-icon plugin that draws
// icons inside the chart, just below the bars/lines (above the tick labels).
export default class extends Controller {
  static targets = [
    "payload", "weatherAssets",
    "dailyCanvas", "ratiosCanvas", "detailCanvas",
    "dailyWeatherCheckbox", "detailWeatherCheckbox",
  ]

  connect() {
    this.dailyChart = null
    this.ratiosChart = null
    this.detailChart = null
    this.payload = this._readPayload()
    this.assetMap = this._readAssetMap()
    this.imageCache = {}
    this.dailyWeatherEnabled = !this.hasDailyWeatherCheckboxTarget || this.dailyWeatherCheckboxTarget.checked
    this.detailWeatherEnabled = !this.hasDetailWeatherCheckboxTarget || this.detailWeatherCheckboxTarget.checked
    this._preloadIconImages().then(() => {
      this._buildDailyChart()
      this._buildRatiosChart()
      this._buildDetailChart()
    })
  }

  disconnect() {
    this.dailyChart?.destroy()
    this.ratiosChart?.destroy()
    this.detailChart?.destroy()
  }

  toggleDailyWeather(event) {
    this.dailyWeatherEnabled = event.target.checked
    this._setSolarVisibility(this.dailyChart, this.dailyWeatherEnabled)
    this.dailyChart?.update()
  }

  toggleDetailWeather(event) {
    this.detailWeatherEnabled = event.target.checked
    this._setSolarVisibility(this.detailChart, this.detailWeatherEnabled)
    this.detailChart?.update()
  }

  _setSolarVisibility(chart, visible) {
    if (!chart) return
    chart.data.datasets.forEach((ds, idx) => {
      if (ds._isSolar) chart.setDatasetVisibility(idx, visible)
    })
    if (chart.options._weatherIcons) {
      chart.options._weatherIcons.enabled = visible
      const padOn = chart.options._weatherIcons.paddingOn ?? 0
      if (chart.options.scales?.x?.ticks) {
        chart.options.scales.x.ticks.padding = visible ? padOn : 0
      }
    }
    if (chart.options.scales?.ySolar) {
      chart.options.scales.ySolar.display = visible
    }
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

  _readAssetMap() {
    if (!this.hasWeatherAssetsTarget) return {}
    try {
      return JSON.parse(this.weatherAssetsTarget.textContent)
    } catch (error) {
      console.error("weather asset map parse failed:", error)
      return {}
    }
  }

  _preloadIconImages() {
    const names = Object.keys(this.assetMap)
    if (names.length === 0) return Promise.resolve()
    return Promise.all(names.map((name) => {
      return new Promise((resolve) => {
        const img = new Image()
        img.onload = () => { this.imageCache[name] = img; resolve() }
        img.onerror = () => { resolve() }
        img.src = this.assetMap[name]
      })
    }))
  }

  _weatherIconsPlugin() {
    const cache = this.imageCache
    return {
      id: "weatherIcons",
      afterDatasetsDraw(chart, _args, _opts) {
        const cfg = chart.options._weatherIcons
        if (!cfg || !cfg.enabled) return
        const icons = cfg.icons || []
        if (icons.length === 0) return
        const xScale = chart.scales.x
        if (!xScale) return
        const { ctx, chartArea } = chart
        const size = cfg.size || 22
        // Draw icons in the gap between the chart area and the tick labels.
        // We open that gap via scales.x.ticks.padding. Extra breathing room
        // between the axis line and the icons keeps things from feeling cramped.
        const gap = cfg.gap ?? 14
        const y = chartArea.bottom + gap + (size / 2)
        ctx.save()
        icons.forEach((icon) => {
          const img = cache[icon.asset_name]
          if (!img) return
          const x = xScale.getPixelForValue(icon.label_index)
          if (x === undefined || x === null) return
          ctx.drawImage(img, x - size / 2, y - size / 2, size, size)
        })
        ctx.restore()
      }
    }
  }

  _buildDailyChart() {
    if (!this.hasDailyCanvasTarget) return

    const daily = this.payload.daily || {}
    const labels = daily.labels || []
    const consumerDatasets = this._consumerBarDatasets(daily.consumer_series || [])
    const consumedDatasets = consumerDatasets.length > 0 ? consumerDatasets : [
      { label: "Verbrauch", data: daily.consumed_kwh || [], backgroundColor: "#3b82f6", stack: "consumed" },
    ]

    const datasets = [
      { label: "Ertrag", data: daily.produced_kwh || [], backgroundColor: "#f59f00", stack: "produced" },
      ...consumedDatasets,
    ]

    const w = daily.weather
    const hasIcons = w && Array.isArray(w.icons) && w.icons.length > 0
    const hasSolar = w && Array.isArray(w.solar_kwh_per_m2)

    const dailyIconsPadding = 44
    const trimXScale = function(scale) {
      const pad = scale.options.ticks?.padding || 0
      if (pad > 0 && scale.height > pad) {
        scale.height -= pad
        scale.bottom -= pad
        if (scale.paddingBottom != null) scale.paddingBottom = Math.max(0, scale.paddingBottom - pad)
      }
    }
    const scales = {
      x: {
        stacked: true,
        ticks: { padding: hasIcons && this.dailyWeatherEnabled ? dailyIconsPadding : 0 },
        afterFit: trimXScale,
      },
      y: { stacked: true, beginAtZero: true, title: { display: true, text: "kWh" } },
    }

    if (hasSolar) {
      datasets.push({
        type: "line",
        label: "Sonnenstrahlung",
        data: w.solar_kwh_per_m2,
        yAxisID: "ySolar",
        borderColor: "#fbbf24",
        backgroundColor: "#fbbf24",
        pointRadius: 3,
        tension: 0.2,
        spanGaps: true,
        order: 0,
        hidden: !this.dailyWeatherEnabled,
        _isSolar: true,
      })
      scales.ySolar = {
        position: "right",
        beginAtZero: true,
        grid: { drawOnChartArea: false },
        title: { display: true, text: "kWh/m²" },
        display: this.dailyWeatherEnabled,
      }
    }

    const iconList = hasIcons
      ? w.icons.map((icon, idx) => icon ? { label_index: idx, asset_name: icon.asset_name } : null).filter(Boolean)
      : []

    this.dailyChart = this._replaceChart(this.dailyCanvasTarget, {
      type: "bar",
      data: { labels, datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales,
        plugins: { legend: { position: "bottom", labels: { boxWidth: 12, boxHeight: 12, padding: 10, font: { size: 12 } } } },
        animation: false,
        _weatherIcons: { enabled: this.dailyWeatherEnabled, icons: iconList, size: 32, gap: 8, paddingOn: dailyIconsPadding },
      },
      plugins: [this._weatherIconsPlugin()],
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
      type: "bar",
      data: {
        labels,
        datasets: [
          { label: "Autarkie", data: autarky, backgroundColor: "#10b981" },
          { label: "Eigenverbrauch", data: selfCons, backgroundColor: "#f59f00" },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: { y: { min: 0, max: 100, title: { display: true, text: "%" } } },
        plugins: { legend: { position: "bottom", labels: { boxWidth: 12, boxHeight: 12, padding: 10, font: { size: 12 } } } },
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

    const w = detail.weather
    const hasIcons = w && Array.isArray(w.icons) && w.icons.length > 0
    const hasSolar = w && Array.isArray(w.solar_w_per_m2)

    const detailIconsPadding = 38
    const trimXScale = function(scale) {
      const pad = scale.options.ticks?.padding || 0
      if (pad > 0 && scale.height > pad) {
        scale.height -= pad
        scale.bottom -= pad
        if (scale.paddingBottom != null) scale.paddingBottom = Math.max(0, scale.paddingBottom - pad)
      }
    }
    const scales = {
      x: { ticks: { maxTicksLimit: 21, autoSkip: true, padding: hasIcons && this.detailWeatherEnabled ? detailIconsPadding : 0 }, afterFit: trimXScale },
      y: { beginAtZero: true, title: { display: true, text: "Watt" } },
    }

    if (hasSolar) {
      datasets.push({
        label: "Sonnenstrahlung",
        data: w.solar_w_per_m2,
        yAxisID: "ySolar",
        borderColor: "#fbbf24",
        backgroundColor: "rgba(251,191,36,0.18)",
        stepped: "before",
        fill: true,
        pointRadius: 0,
        spanGaps: true,
        hidden: !this.detailWeatherEnabled,
        _isSolar: true,
      })
      scales.ySolar = {
        position: "right",
        beginAtZero: true,
        grid: { drawOnChartArea: false },
        title: { display: true, text: "W/m²" },
        display: this.detailWeatherEnabled,
      }
    }

    this.detailChart = this._replaceChart(this.detailCanvasTarget, {
      type: "line",
      data: { labels, datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales,
        plugins: { legend: { position: "bottom", labels: { boxWidth: 12, boxHeight: 12, padding: 10, font: { size: 12 } } } },
        animation: false,
        _weatherIcons: { enabled: this.detailWeatherEnabled, icons: hasIcons ? w.icons : [], size: 28, gap: 8, paddingOn: detailIconsPadding },
      },
      plugins: [this._weatherIconsPlugin()],
    })
  }

  _buildDailyPowerBarChart(detail) {
    const labels = detail.labels || []
    const producerDatasets = (detail.series || [])
      .filter((series) => series.role === "producer")
      .map((series) => ({
        label: series.name, data: series.data || [],
        backgroundColor: "#f59f00", stack: "produced",
      }))
    const consumerDatasets = this._consumerBarDatasets(
      (detail.series || []).filter((series) => series.role === "consumer")
    )

    this.detailChart = this._replaceChart(this.detailCanvasTarget, {
      type: "bar",
      data: { labels, datasets: [ ...producerDatasets, ...consumerDatasets ] },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: {
          x: { stacked: true },
          y: { stacked: true, beginAtZero: true, title: { display: true, text: "Watt" } },
        },
        plugins: { legend: { position: "bottom", labels: { boxWidth: 12, boxHeight: 12, padding: 10, font: { size: 12 } } } },
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
      label: row.name, data: row.data || [],
      backgroundColor: colors[index % colors.length], stack: "consumed",
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
      label: "Gesamtverbrauch", data,
      borderColor: "#1d4ed8", backgroundColor: "rgba(59, 130, 246, 0.14)",
      fill: true, tension: 0.2, pointRadius: 0,
    }
  }
}

import { Controller } from "@hotwired/stimulus"
import "chart.js"

// Connects to data-controller="history-chart"
// Loads the 14-day bar chart once on connect. No live updates needed —
// data changes at most once per day (after the nightly aggregation job).
export default class extends Controller {
  static targets = ["canvas"]

  connect() {
    this.chart = null
    this.loadChart()
  }

  disconnect() {
    this.chart?.destroy()
  }

  async loadChart() {
    try {
      const response = await fetch("/api/history?days=14")
      if (!response.ok) return
      const data = await response.json()
      this._buildChart(data)
    } catch (e) {
      console.error("history chart load failed:", e)
    }
  }

  _buildChart(data) {
    const producer = data.series.find(s => s.role === "producer")
    if (!producer) return

    const labels = producer.points.map(p => p.date)
    const values = producer.points.map(p => p.energy_wh / 1000)

    this.chart?.destroy()
    if (!this.hasCanvasTarget) return
    this.chart = new Chart(this.canvasTarget, {
      type: "bar",
      data: {
        labels,
        datasets: [{ label: "kWh/Tag", data: values, backgroundColor: "#f59f00" }],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: { y: { beginAtZero: true, title: { display: true, text: "kWh" } } },
        plugins: { legend: { display: false } },
        animation: false,
      },
    })
  }
}

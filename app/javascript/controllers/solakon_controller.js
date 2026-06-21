import { Controller } from "@hotwired/stimulus"
import "chart.js"
import consumer from "channels/consumer"

export default class extends Controller {
  static targets = [
    "historyCanvas", "historyPayload", "balanceRows",
    "epsToggle", "epsState", "epsPower", "epsVoltage", "epsError",
    "autoRegulationToggle", "autoRegulationState", "autoRegulationHelp", "autoRegulationError",
    "efPvW", "efGridW", "efConsumerW", "efBatterySoc", "efBatteryW",
    "efLineSolarHome", "efLineSolarGrid", "efLineSolarBattery",
    "efLineGridHome", "efLineGridBattery", "efLineBatteryHome",
    "efDotsSolarHome", "efDotsSolarGrid", "efDotsSolarBattery",
    "efDotsGridHome", "efDotsGridBattery", "efDotsBatteryHome",
    "efConsumerRing",
  ]

  connect() {
    this.chart = null
    this.efLastDur = {}
    this._buildChart(this._readPayload())
    this.subscription = consumer.subscriptions.create("DashboardChannel", {
      received: (data) => {
        if (data.energy_flow) this.updateEnergyFlow(data.energy_flow)
        if (data.solakon) this.fetchLive()
      },
    })
    this.fetchLive()
  }

  disconnect() {
    this.subscription?.unsubscribe()
    this.chart?.destroy()
  }

  async selectRange(event) {
    const range = event.currentTarget.dataset.solakonRangeParam
    try {
      const response = await fetch(`/solakon/history.json?range=${encodeURIComponent(range)}`)
      if (!response.ok) return
      const payload = await response.json()
      this.element.querySelectorAll(".preset-link").forEach((button) => button.classList.toggle("active", button === event.currentTarget))
      this._buildChart(payload)
      this._renderBalanceRows(payload.balance_rows || [])
    } catch (error) {
      console.error("solakon history load failed:", error)
    }
  }

  async toggleEps(event) {
    const desired = event.target.checked
    this._hideError(this.epsErrorTarget)
    try {
      const response = await fetch("/solakon/eps", {
        method: "PATCH",
        headers: this._jsonHeaders(),
        body: JSON.stringify({ enabled: desired }),
      })
      const data = await response.json()
      if (!response.ok) throw new Error(data.error || "Schalten fehlgeschlagen")
      this.epsStateTarget.textContent = data.enabled ? "An" : "Aus"
      event.target.checked = data.enabled
    } catch (error) {
      event.target.checked = !desired
      this._showError(this.epsErrorTarget, error.message)
    }
  }

  async toggleAutoRegulation(event) {
    const desired = event.target.checked
    this._hideError(this.autoRegulationErrorTarget)
    try {
      const response = await fetch("/solakon/auto_regulation", {
        method: "PATCH",
        headers: this._jsonHeaders(),
        body: JSON.stringify({ active: desired }),
      })
      const data = await response.json()
      if (!response.ok) throw new Error(data.error || "Umschalten fehlgeschlagen")
      event.target.checked = data.active
      this.autoRegulationStateTarget.textContent = data.active ? "Aktiv" : "Pausiert"
      this.autoRegulationHelpTarget.textContent = data.active ? "hält Einspeisung nahe 0 W" : "pausiert"
    } catch (error) {
      event.target.checked = !desired
      this._showError(this.autoRegulationErrorTarget, error.message)
    }
  }

  async fetchLive() {
    try {
      const response = await fetch("/api/live")
      if (!response.ok) return
      const data = await response.json()
      if (data.energy_flow) this.updateEnergyFlow(data.energy_flow)
    } catch (error) {
      console.error("solakon fetchLive failed:", error)
    }
  }

  updateEnergyFlow(flow) {
    const pvW = flow.solakon_online ? Math.max(0, flow.solar_w || 0) : null
    const homeW = flow.home_w
    const gridW = flow.grid_w
    const batteryW = flow.battery_w
    const batterySoc = flow.battery_soc_pct

    if (this.hasEfPvWTarget) this.efPvWTarget.textContent = pvW == null ? "— W" : `${pvW.toFixed(0)} W`
    if (this.hasEfConsumerWTarget) this.efConsumerWTarget.textContent = homeW == null ? "— W" : `${homeW.toFixed(0)} W`
    if (this.hasEfGridWTarget) this.efGridWTarget.textContent = gridW == null ? "— W" : gridW > 0 ? `+${gridW.toFixed(0)} W` : gridW < 0 ? `−${Math.abs(gridW).toFixed(0)} W` : "0 W"
    if (this.hasEfBatterySocTarget) this.efBatterySocTarget.textContent = batterySoc == null ? "— %" : `${batterySoc.toFixed(0)}%`
    if (this.hasEfBatteryWTarget) this.efBatteryWTarget.textContent = batteryW == null ? "— W" : batteryW > 0 ? `−${batteryW.toFixed(0)} W` : batteryW < 0 ? `${Math.abs(batteryW).toFixed(0)} W` : "0 W"

    const flows = flow?.flows || {}
    const solarToHome = Number(flows.solar_to_home_w || 0)
    const solarToGrid = Number(flows.solar_to_grid_w || 0)
    const solarToBattery = Number(flows.solar_to_battery_w || 0)
    const gridToHome = Number(flows.grid_to_home_w || 0)
    const gridToBattery = Number(flows.grid_to_battery_w || 0)
    const batteryToHome = Number(flows.battery_to_home_w || 0)

    const paths = {
      solarHome: "M 200,122 C 205,150 250,166 306,170",
      solarGrid: "M 200,122 C 195,150 150,166 94,170",
      solarBattery: "M 200,122 L 200,218",
      gridHome: "M 94,170 L 306,170",
      gridBattery: "M 94,170 C 150,174 195,190 200,218",
      batteryHome: "M 200,218 C 205,190 250,174 306,170",
    }
    const lens = { solarHome: 123, solarGrid: 123, solarBattery: 96, gridHome: 212, gridBattery: 123, batteryHome: 123 }

    this._efSetDots("efDotsSolarHomeTarget", paths.solarHome, "#f59f00", solarToHome, lens.solarHome)
    this._efSetDots("efDotsSolarGridTarget", paths.solarGrid, "#8b5cf6", solarToGrid, lens.solarGrid)
    this._efSetDots("efDotsSolarBatteryTarget", paths.solarBattery, "#ec4899", solarToBattery, lens.solarBattery)
    this._efSetDots("efDotsGridHomeTarget", paths.gridHome, "#3b82f6", gridToHome, lens.gridHome)
    this._efSetDots("efDotsGridBatteryTarget", paths.gridBattery, "#94a3b8", gridToBattery, lens.gridBattery)
    this._efSetDots("efDotsBatteryHomeTarget", paths.batteryHome, "#14b8a6", batteryToHome, lens.batteryHome)
  }

  _readPayload() {
    try {
      return JSON.parse(this.historyPayloadTarget.textContent)
    } catch (error) {
      return { chart: { labels: [], datasets: [] }, balance_rows: [] }
    }
  }

  _buildChart(payload) {
    if (!this.hasHistoryCanvasTarget) return
    const chart = payload?.chart || { labels: [], datasets: [] }
    const colors = { "PV": "#f59f00", "Akku": "#14b8a6", "Netz": "#3b82f6", "0 W": "#6c757d" }
    const datasets = (chart.datasets || []).map((dataset) => ({
      label: dataset.label,
      data: dataset.data,
      borderColor: colors[dataset.label] || "#6c757d",
      backgroundColor: dataset.label === "PV" ? "rgba(245,159,0,0.14)" : "transparent",
      borderDash: dataset.label === "0 W" ? [4, 4] : [],
      fill: dataset.label === "PV",
      pointRadius: 0,
      tension: 0.2,
    }))

    this.chart?.destroy()
    this.chart = new Chart(this.historyCanvasTarget, {
      type: "line",
      data: { labels: chart.labels || [], datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: { y: { title: { display: true, text: "Watt" } } },
        plugins: { legend: { position: "bottom", labels: { boxWidth: 12, boxHeight: 12, padding: 10, font: { size: 12 } } } },
        animation: false,
      },
    })
  }

  _renderBalanceRows(rows) {
    if (!this.hasBalanceRowsTarget) return
    this.balanceRowsTarget.innerHTML = rows.map((row) => `
      <div class="solakon-balance-row ${row.role}">
        <span class="solakon-balance-label">${row.label}</span>
        <span class="report-ranking-bar" aria-hidden="true"><span style="width: ${row.share}%"></span></span>
        <span class="report-ranking-value">${row.value}</span>
      </div>
    `).join("")
  }

  _jsonHeaders() {
    return {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content,
    }
  }

  _showError(target, message) {
    target.textContent = message
    target.hidden = false
  }

  _hideError(target) {
    target.textContent = ""
    target.hidden = true
  }

  _efDur(w, len) {
    return w < 1 ? null : Math.max(0.5, Math.min(8, len / w))
  }

  _efSetDots(targetName, path, color, w, len) {
    const target = this[targetName]
    if (!target) return
    const dur = this._efDur(w, len)
    const prev = this.efLastDur[targetName]
    const changed = dur === null ? prev != null : prev == null || Math.abs(dur - prev) / prev > 0.05
    if (!changed) return
    this.efLastDur[targetName] = dur
    target.innerHTML = ""
    if (!dur) return
    const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    for (let i = 0; i < 3; i++) {
      const c = document.createElementNS("http://www.w3.org/2000/svg", "circle")
      c.setAttribute("r", "4.5")
      c.setAttribute("fill", color)
      c.style.cssText = reduceMotion ? `offset-path:path("${path}");offset-distance:${25 + i * 25}%` : `offset-path:path("${path}")`
      target.appendChild(c)
      if (!reduceMotion) {
        c.animate([{ offsetDistance: "0%" }, { offsetDistance: "100%" }], { duration: dur * 1000, delay: -(i * dur / 3) * 1000, iterations: Infinity, easing: "linear" })
      }
    }
  }
}

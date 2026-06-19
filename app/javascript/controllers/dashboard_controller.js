import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

// Connects to data-controller="dashboard"
// Manages: hero watt display, live tiles (consumption/balance), plug chips,
//          energy flow SVG, and periodic today-summary fetch.
export default class extends Controller {
  static targets = [
    "heroValue",
    "tileConsumption", "tileNetbalance",
    "tileProduced", "tileConsumed", "tileSavings", "tileNettoday",
    "tileAutarky", "tileSelfConsumption",
    "plugList",
    // Energy flow SVG elements
    "efPvW", "efGridW", "efConsumerW", "efBatterySoc", "efBatteryW",
    "efLineSolarHome", "efLineSolarGrid", "efLineSolarBattery",
    "efLineGridHome", "efLineGridBattery", "efLineBatteryHome",
    "efDotsSolarHome", "efDotsSolarGrid", "efDotsSolarBattery",
    "efDotsGridHome", "efDotsGridBattery", "efDotsBatteryHome",
  ]

  connect() {
    // Keyed by plug_id — holds latest broadcast per plug
    this.plugState = {}
    this.plugChips = {}
    this.efLastDur = {}
    this.energyFlow = null

    this.subscription = consumer.subscriptions.create("DashboardChannel", {
      received: (data) => this.handleReading(data),
    })

    this.fetchLive()

    // Summary tiles are cumulative daily values — not per-plug,
    // so we fetch them periodically via HTTP rather than ActionCable.
    this.fetchSummary()
    this.summaryInterval = setInterval(() => this.fetchSummary(), 30_000)
  }

  disconnect() {
    this.subscription?.unsubscribe()
    clearInterval(this.summaryInterval)
  }

  // Called for every bundled broadcast from Poller
  handleReading(data) {
    if (data.energy_flow) this.energyFlow = data.energy_flow

    if (Array.isArray(data.plugs)) {
      data.plugs.forEach((plug) => this.applyPlugState(plug))
      this.renderLiveState()
    }

    if (data.solakon) this.fetchLive()
  }

  applyPlugState(data) {
    const plugId = data.plug_id || data.id
    if (!plugId) return

    const ts = data.ts || data.last_seen_ts || 0
    const current = this.plugState[plugId]
    const currentTs = current?.ts || current?.last_seen_ts || 0
    if (current && ts < currentTs) return

    this.plugState[plugId] = {
      ...data,
      plug_id: plugId,
      ts: ts,
    }
  }

  renderLiveState() {
    const plugs = Object.values(this.plugState)
    this.updateHero(plugs)
    this.updateLiveTiles(plugs)
    this.updatePlugChips(plugs)
    this.updateEnergyFlow(plugs)
  }

  async fetchLive() {
    try {
      const response = await fetch("/api/live")
      if (!response.ok) return
      const data = await response.json()
      if (data.energy_flow) this.energyFlow = data.energy_flow

      if (Array.isArray(data.plugs))
        data.plugs.forEach((plug) => this.applyPlugState(plug))
      this.renderLiveState()
    } catch (e) {
      console.error("fetchLive failed:", e)
    }
  }

  // --- Hero ---

  updateHero(plugs) {
    if (!this.hasHeroValueTarget) return
    const flow = this.energyFlow
    const producer = plugs.find(p => p.role === "producer")
    const fallbackW = producer?.online ? Math.abs(producer.apower_w).toFixed(0) : "—"
    const w = flow ? (flow.solakon_online ? Math.max(0, flow.solar_w || 0).toFixed(0) : "—") : fallbackW
    this.heroValueTarget.innerHTML = `<span class="hero-number">${w}</span> <span class="hero-unit">W</span>`
  }

  // --- Live tiles ---

  updateLiveTiles(plugs) {
    const flow = this.energyFlow
    const consumers = plugs.filter(p => p.role === "consumer")
    const conW = flow?.home_w ?? consumers.reduce((s, p) => s + (p.online ? p.apower_w : 0), 0)
    const gridW = flow?.grid_w

    // No online plug at all → show the dash placeholder, consistent with the hero,
    // rather than a misleading "0 W" that looks like a real measured zero.
    const anyOnline = flow?.solakon_online || plugs.some(p => p.online)

    if (this.hasTileConsumptionTarget)
      this.tileConsumptionTarget.textContent = anyOnline ? conW.toFixed(0) + " W" : "—"
    if (this.hasTileNetbalanceTarget)
      this.tileNetbalanceTarget.textContent = gridW == null ? "—" : (gridW <= 0 ? "+" : "−") + Math.abs(gridW).toFixed(0) + " W"
  }

  // --- Plug chips ---

  updatePlugChips(plugs) {
    if (!this.hasPlugListTarget) return
    if (!this.plugListInitialized) {
      this.plugListTarget.textContent = ""
      this.plugListInitialized = true
    }
    const seen = new Set()

    for (const p of plugs) {
      seen.add(p.plug_id)
      const chip = this._plugChip(p)
      const dot = chip.querySelector(".dot")
      const name = chip.querySelector(".plug-name")
      const value = chip.querySelector(".plug-value")

      chip.classList.toggle("offline", !p.online)
      dot.classList.toggle("offline", !p.online)
      name.textContent = p.name
      const label = p.online
        ? `${p.apower_w.toFixed(0)} W`
        : "offline"
      value.textContent = label
    }

    for (const [id, chip] of Object.entries(this.plugChips)) {
      if (seen.has(id)) continue
      chip.remove()
      delete this.plugChips[id]
    }
  }

  _plugChip(plug) {
    let chip = this.plugChips[plug.plug_id]
    if (chip) return chip

    chip = document.createElement("span")
    chip.className = "plug-chip"

    const dot = document.createElement("span")
    dot.className = "dot"
    chip.appendChild(dot)

    const name = document.createElement("span")
    name.className = "plug-name"
    chip.appendChild(name)

    chip.appendChild(document.createTextNode(" · "))

    const value = document.createElement("span")
    value.className = "plug-value"
    chip.appendChild(value)

    this.plugChips[plug.plug_id] = chip
    this.plugListTarget.appendChild(chip)
    return chip
  }

  // --- Energy flow SVG ---

  updateEnergyFlow(plugs) {
    const flow = this.energyFlow
    const consumers = plugs.filter(p => p.role === "consumer")
    const fallbackHomeW = consumers.reduce((s, p) => s + (p.online ? p.apower_w : 0), 0)
    const solakonOnline = flow?.solakon_online
    const pvW = solakonOnline ? Math.max(0, flow.solar_w || 0) : null
    const homeW = flow?.home_w ?? fallbackHomeW
    const gridW = flow?.grid_w
    const batteryW = flow?.battery_w
    const batterySoc = flow?.battery_soc_pct

    const gridToHome = gridW > 0 ? gridW : 0
    const solarToGrid = gridW < 0 ? Math.abs(gridW) : 0
    const solarToBattery = batteryW > 0 ? batteryW : 0
    const batteryToHome = batteryW < 0 ? Math.abs(batteryW) : 0
    const solarToHome = pvW == null ? 0 : Math.max(0, pvW - solarToGrid - solarToBattery)

    if (this.hasEfPvWTarget)
      this.efPvWTarget.textContent = pvW == null ? "— W" : pvW.toFixed(0) + " W"
    if (this.hasEfConsumerWTarget)
      this.efConsumerWTarget.textContent = (solakonOnline || plugs.some(p => p.online)) ? homeW.toFixed(0) + " W" : "— W"
    if (this.hasEfGridWTarget) {
      this.efGridWTarget.textContent =
        gridW == null ? "— W" :
        gridW > 0 ? "+" + gridW.toFixed(0) + " W" :
        gridW < 0 ? "−" + Math.abs(gridW).toFixed(0) + " W" : "0 W"
    }
    if (this.hasEfBatterySocTarget)
      this.efBatterySocTarget.textContent = batterySoc == null ? "— %" : batterySoc.toFixed(0) + "%"
    if (this.hasEfBatteryWTarget)
      this.efBatteryWTarget.textContent =
        batteryW == null ? "— W" :
        batteryW > 0 ? "+" + batteryW.toFixed(0) + " W" :
        batteryW < 0 ? "−" + Math.abs(batteryW).toFixed(0) + " W" : "0 W"

    const EF_PATHS = {
      solarHome: "M 200,122 C 205,150 250,176 290,180",
      solarGrid: "M 200,122 C 195,150 150,176 110,180",
      solarBattery: "M 200,122 L 200,218",
      gridHome: "M 110,180 L 290,180",
      gridBattery: "M 104,206 C 135,235 160,255 200,218",
      batteryHome: "M 200,218 C 240,255 265,235 296,206",
    }
    const EF_LENS = {
      solarHome: 153,
      solarGrid: 157,
      solarBattery: 100,
      gridHome: 200,
      gridBattery: 111,
      batteryHome: 108,
    }

    this._efSetDots("efDotsSolarHomeTarget", EF_PATHS.solarHome, "#f59f00", solarToHome, EF_LENS.solarHome)
    this._efSetDots("efDotsSolarGridTarget", EF_PATHS.solarGrid, "#8b5cf6", solarToGrid, EF_LENS.solarGrid)
    this._efSetDots("efDotsSolarBatteryTarget", EF_PATHS.solarBattery, "#ec4899", solarToBattery, EF_LENS.solarBattery)
    this._efSetDots("efDotsGridHomeTarget", EF_PATHS.gridHome, "#3b82f6", gridToHome, EF_LENS.gridHome)
    this._efSetDots("efDotsGridBatteryTarget", EF_PATHS.gridBattery, "#94a3b8", 0, EF_LENS.gridBattery)
    this._efSetDots("efDotsBatteryHomeTarget", EF_PATHS.batteryHome, "#14b8a6", batteryToHome, EF_LENS.batteryHome)
  }

  _efDur(w, len) {
    return w < 1 ? null : Math.max(0.5, Math.min(8, len / w))
  }

  _efSetDots(targetName, path, color, w, len) {
    const target = this[targetName]
    if (!target) return
    const dur = this._efDur(w, len)
    const id  = targetName
    const prev = this.efLastDur[id]
    const changed = dur === null ? prev != null
                                 : prev == null || Math.abs(dur - prev) / prev > 0.05
    if (!changed) return
    this.efLastDur[id] = dur
    target.innerHTML = ""
    if (!dur) return

    // Respect prefers-reduced-motion: place static dots, skip the infinite animation.
    const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches

    for (let i = 0; i < 3; i++) {
      const c = document.createElementNS("http://www.w3.org/2000/svg", "circle")
      c.setAttribute("r", "4.5")
      c.setAttribute("fill", color)
      if (reduceMotion) {
        c.style.cssText = `offset-path:path("${path}");offset-distance:${25 + i * 25}%`
        target.appendChild(c)
      } else {
        c.style.cssText = `offset-path:path("${path}")`
        target.appendChild(c)
        c.animate(
          [{ offsetDistance: "0%" }, { offsetDistance: "100%" }],
          { duration: dur * 1000, delay: -(i * dur / 3) * 1000, iterations: Infinity, easing: "linear" }
        )
      }
    }
  }

  // --- Summary tiles (periodic HTTP) ---

  async fetchSummary() {
    try {
      const response = await fetch("/api/today/summary")
      if (!response.ok) return
      const data = await response.json()
      const fmt = (n, d = 2) => n.toFixed(d).replace(".", ",")

      if (this.hasTileProducedTarget)
        this.tileProducedTarget.textContent  = fmt(data.produced_wh_today / 1000) + " kWh"
      if (this.hasTileConsumedTarget)
        this.tileConsumedTarget.textContent  = fmt(data.consumed_wh_today / 1000) + " kWh"
      if (this.hasTileSavingsTarget)
        this.tileSavingsTarget.textContent   = fmt(data.savings_eur_today) + " €"
      if (this.hasTileNettodayTarget) {
        const net = (data.produced_wh_today - data.consumed_wh_today) / 1000
        this.tileNettodayTarget.textContent  = (net >= 0 ? "+" : "") + fmt(net) + " kWh"
      }
      const fmtPct = (ratio) => fmt(ratio * 100, 1) + " %"
      if (this.hasTileAutarkyTarget)
        this.tileAutarkyTarget.textContent = fmtPct(data.autarky_ratio || 0)
      if (this.hasTileSelfConsumptionTarget)
        this.tileSelfConsumptionTarget.textContent = fmtPct(data.self_consumption_ratio || 0)
    } catch (e) {
      console.error("fetchSummary failed:", e)
    }
  }
}

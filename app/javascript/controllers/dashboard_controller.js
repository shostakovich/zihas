import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

// Connects to data-controller="dashboard"
// Manages: hero watt display, live tiles (consumption/balance), plug chips,
//          energy flow SVG, and periodic today-summary fetch.
export default class extends Controller {
  static targets = [
    "heroValue", "heroBattery", "heroBatterySoc",
    "tileConsumption", "tileNetbalance",
    "tileProduced", "tileConsumed", "tileSavings", "tileNettoday",
    "tileAutarky", "tileSelfConsumption",
    "plugList",
    // Energy flow SVG elements
    "efPvW", "efGridW", "efConsumerW", "efBatterySoc", "efBatteryW", "efBatteryImage",
    "efLineSolarHome", "efLineSolarGrid", "efLineSolarBattery",
    "efLineGridHome", "efLineGridBattery", "efLineBatteryHome",
    "efDotsSolarHome", "efDotsSolarGrid", "efDotsSolarBattery",
    "efDotsGridHome", "efDotsGridBattery", "efDotsBatteryHome",
    "efConsumerRing",
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
    // Use the Solakon PV value only when its reading is live; otherwise fall back
    // to the producer plug so dashboards without Solakon keep showing live watts.
    const w = flow?.solakon_online ? Math.max(0, flow.solar_w || 0).toFixed(0) : fallbackW
    this.heroValueTarget.innerHTML = `<span class="hero-number">${w}</span> <span class="hero-unit">W</span>`

    // The battery half is Solakon-only: hide it entirely when there is no live
    // Solakon reading, so setups without a battery look unchanged.
    if (this.hasHeroBatteryTarget) {
      const online = !!flow?.solakon_online
      this.heroBatteryTarget.hidden = !online
      if (online) {
        const soc = flow.battery_soc_pct
        const s = soc == null ? "—" : soc.toFixed(0)
        this.heroBatterySocTarget.innerHTML = `<span class="hero-number">${s}</span> <span class="hero-unit">%</span>`
      }
    }
  }

  // --- Live tiles ---

  updateLiveTiles(plugs) {
    const flow = this.energyFlow
    const consumers = plugs.filter(p => p.role === "consumer")
    const conW = flow ? flow.home_w : consumers.reduce((s, p) => s + (p.online ? p.apower_w : 0), 0)
    const gridW = flow?.grid_w

    // No online plug at all → show the dash placeholder, consistent with the hero,
    // rather than a misleading "0 W" that looks like a real measured zero.
    const anyOnline = flow?.solakon_online || plugs.some(p => p.online)

    if (this.hasTileConsumptionTarget)
      this.tileConsumptionTarget.textContent = anyOnline && conW != null ? conW.toFixed(0) + " W" : "—"
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
    const homeW = flow ? flow.home_w : fallbackHomeW
    const gridW = flow?.grid_w
    const batteryW = flow?.battery_w
    const batterySoc = flow?.battery_soc_pct

    const flows = flow?.flows || {}
    const solarToHome = Number(flows.solar_to_home_w || 0)
    const solarToGrid = Number(flows.solar_to_grid_w || 0)
    const solarToBattery = Number(flows.solar_to_battery_w || 0)
    const gridToHome = Number(flows.grid_to_home_w || 0)
    const gridToBattery = Number(flows.grid_to_battery_w || 0)
    const batteryToHome = Number(flows.battery_to_home_w || 0)

    if (this.hasEfPvWTarget)
      this.efPvWTarget.textContent = pvW == null ? "— W" : pvW.toFixed(0) + " W"
    if (this.hasEfConsumerWTarget)
      this.efConsumerWTarget.textContent = homeW == null ? "— W" : homeW.toFixed(0) + " W"
    if (this.hasEfGridWTarget) {
      this.efGridWTarget.textContent =
        gridW == null ? "— W" :
        gridW > 0 ? "+" + gridW.toFixed(0) + " W" :
        gridW < 0 ? "−" + Math.abs(gridW).toFixed(0) + " W" : "0 W"
    }
    if (this.hasEfBatterySocTarget)
      this.efBatterySocTarget.textContent = batterySoc == null ? "— %" : batterySoc.toFixed(0) + "%"
    this._efSetBatteryImage(flow?.battery_state)

    if (this.hasEfBatteryWTarget)
      // Charging (positive display power) is drawn from the household, so it
      // gets a "−"; discharging feeds the house and is shown without a sign.
      this.efBatteryWTarget.textContent =
        batteryW == null ? "— W" :
        batteryW > 0 ? "−" + batteryW.toFixed(0) + " W" :
        batteryW < 0 ? Math.abs(batteryW).toFixed(0) + " W" : "0 W"

    const EF_PATHS = {
      solarHome: "M 200,122 C 205,150 250,166 306,170",
      solarGrid: "M 200,122 C 195,150 150,166 94,170",
      solarBattery: "M 200,122 L 200,218",
      gridHome: "M 94,170 L 306,170",
      gridBattery: "M 94,170 C 150,174 195,190 200,218",
      batteryHome: "M 200,218 C 205,190 250,174 306,170",
    }
    const EF_LENS = {
      solarHome: 123,
      solarGrid: 123,
      solarBattery: 96,
      gridHome: 212,
      gridBattery: 123,
      batteryHome: 123,
    }

    this._efSetDots("efDotsSolarHomeTarget", EF_PATHS.solarHome, "#f59f00", solarToHome, EF_LENS.solarHome)
    this._efSetDots("efDotsSolarGridTarget", EF_PATHS.solarGrid, "#8b5cf6", solarToGrid, EF_LENS.solarGrid)
    this._efSetDots("efDotsSolarBatteryTarget", EF_PATHS.solarBattery, "#ec4899", solarToBattery, EF_LENS.solarBattery)
    this._efSetDots("efDotsGridHomeTarget", EF_PATHS.gridHome, "#3b82f6", gridToHome, EF_LENS.gridHome)
    this._efSetDots("efDotsGridBatteryTarget", EF_PATHS.gridBattery, "#94a3b8", gridToBattery, EF_LENS.gridBattery)
    this._efSetDots("efDotsBatteryHomeTarget", EF_PATHS.batteryHome, "#14b8a6", batteryToHome, EF_LENS.batteryHome)

    // Verbraucher ring: share of consumption by source (solar / grid / battery).
    this._efSetConsumerRing([
      { w: solarToHome,   color: "#f59f00" },
      { w: gridToHome,    color: "#3b82f6" },
      { w: batteryToHome, color: "#14b8a6" },
    ])
  }

  _efSetBatteryImage(state) {
    if (!this.hasEfBatteryImageTarget) return
    const key = state || "normal"
    const src = this.efBatteryImageTarget.dataset[`batteryState${key.charAt(0).toUpperCase()}${key.slice(1)}`]
    if (src) this.efBatteryImageTarget.setAttribute("href", src)
  }

  // Renders the Verbraucher node ring as colored arcs proportional to each
  // energy source feeding the household. Empty input leaves the grey base ring.
  _efSetConsumerRing(sources) {
    const g = this.hasEfConsumerRingTarget ? this.efConsumerRingTarget : null
    if (!g) return
    const segs = sources.filter(s => s.w > 0.5)
    const total = segs.reduce((s, x) => s + x.w, 0)
    g.innerHTML = ""
    if (total <= 0) return

    let acc = 0
    for (const s of segs) {
      const pct = (s.w / total) * 100
      const c = document.createElementNS("http://www.w3.org/2000/svg", "circle")
      c.setAttribute("cx", "342")
      c.setAttribute("cy", "170")
      c.setAttribute("r", "40")
      c.setAttribute("fill", "none")
      c.setAttribute("stroke", s.color)
      c.setAttribute("stroke-width", "2.5")
      c.setAttribute("pathLength", "100")
      c.setAttribute("stroke-dasharray", `${pct} ${100 - pct}`)
      c.setAttribute("stroke-dashoffset", `${-acc}`)
      g.appendChild(c)
      acc += pct
    }
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

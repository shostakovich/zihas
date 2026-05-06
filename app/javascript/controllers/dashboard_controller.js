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
    "efPvW", "efGridW", "efConsumerW",
    "efLineV", "efLineHl", "efLineHr",
    "efRingPv", "efRingGrid",
    "efDotsPvHome", "efDotsGridHome", "efDotsPvGrid",
  ]

  connect() {
    // Keyed by plug_id — holds latest broadcast per plug
    this.plugState = {}
    this.plugChips = {}
    this.efLastDur = {}

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
    if (!Array.isArray(data.plugs)) return

    data.plugs.forEach((plug) => this.applyPlugState(plug))
    this.renderLiveState()
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
      if (!Array.isArray(data.plugs)) return

      data.plugs.forEach((plug) => this.applyPlugState(plug))
      this.renderLiveState()
    } catch (e) {
      console.error("fetchLive failed:", e)
    }
  }

  // --- Hero ---

  updateHero(plugs) {
    if (!this.hasHeroValueTarget) return
    const producer = plugs.find(p => p.role === "producer")
    const w = producer?.online ? Math.abs(producer.apower_w).toFixed(0) : "—"
    this.heroValueTarget.innerHTML = `<span class="hero-number">${w}</span> <span class="hero-unit">W</span>`
  }

  // --- Live tiles ---

  updateLiveTiles(plugs) {
    const producer  = plugs.find(p => p.role === "producer")
    const consumers = plugs.filter(p => p.role === "consumer")

    const pvW  = producer?.online ? Math.abs(producer.apower_w) : 0
    const conW = consumers.reduce((s, p) => s + (p.online ? p.apower_w : 0), 0)
    const net  = pvW - conW

    if (this.hasTileConsumptionTarget)
      this.tileConsumptionTarget.textContent = conW.toFixed(0) + " W"
    if (this.hasTileNetbalanceTarget)
      this.tileNetbalanceTarget.textContent = (net >= 0 ? "+" : "") + net.toFixed(0) + " W"
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
    const producer = plugs.find(p => p.role === "producer")
    const pvW      = producer?.online ? Math.abs(producer.apower_w) : 0
    const consW    = plugs.filter(p => p.role === "consumer")
                          .reduce((s, p) => s + (p.online ? p.apower_w : 0), 0)

    const pvToHome   = Math.min(pvW, consW)
    const gridToHome = Math.max(0, consW - pvW)
    const pvToGrid   = Math.max(0, pvW - consW)

    if (this.hasEfPvWTarget)
      this.efPvWTarget.textContent = pvW.toFixed(0) + " W"
    if (this.hasEfConsumerWTarget)
      this.efConsumerWTarget.textContent = consW.toFixed(0) + " W"
    if (this.hasEfGridWTarget) {
      this.efGridWTarget.textContent =
        gridToHome > 0 ? "+" + gridToHome.toFixed(0) + " W" :
        pvToGrid   > 0 ? "−" + pvToGrid.toFixed(0)   + " W" : "0 W"
    }

    const EF_PATHS = {
      pvHome:   "M 200,120 L 200,175 L 298,175",
      gridHome: "M 98,175 L 298,175",
      pvGrid:   "M 200,120 L 200,175 L 98,175",
    }
    const EF_LENS = { pvHome: 153, gridHome: 200, pvGrid: 157 }

    this._efSetDots("efDotsPvHomeTarget",   EF_PATHS.pvHome,   "#f59f00", pvToHome,   EF_LENS.pvHome)
    this._efSetDots("efDotsGridHomeTarget", EF_PATHS.gridHome, "#3b82f6", gridToHome, EF_LENS.gridHome)
    this._efSetDots("efDotsPvGridTarget",   EF_PATHS.pvGrid,   "#f59f00", pvToGrid,   EF_LENS.pvGrid)

    const GRAY = "#dee2e6"
    this._efLine("efLineVTarget",   pvW > 0        ? "#f59f00" : GRAY)
    this._efLine("efLineHrTarget",  gridToHome > 0 ? "#3b82f6" : (pvToHome > 0 ? "#f59f00" : GRAY))
    this._efLine("efLineHlTarget",  gridToHome > 0 ? "#3b82f6" : (pvToGrid > 0 ? "#f59f00" : GRAY))

    const C       = 2 * Math.PI * 44
    const pvArc   = consW > 0 ? (pvToHome   / consW) * C : 0
    const gridArc = consW > 0 ? (gridToHome / consW) * C : 0
    if (this.hasEfRingPvTarget) {
      this.efRingPvTarget.setAttribute("stroke-dasharray",  `${pvArc} ${C}`)
      this.efRingPvTarget.setAttribute("stroke-dashoffset", "0")
    }
    if (this.hasEfRingGridTarget) {
      this.efRingGridTarget.setAttribute("stroke-dasharray",  `${gridArc} ${C}`)
      this.efRingGridTarget.setAttribute("stroke-dashoffset", -pvArc)
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
    for (let i = 0; i < 3; i++) {
      const c = document.createElementNS("http://www.w3.org/2000/svg", "circle")
      c.setAttribute("r", "4.5")
      c.setAttribute("fill", color)
      c.style.cssText = `offset-path:path("${path}")`
      target.appendChild(c)
      c.animate(
        [{ offsetDistance: "0%" }, { offsetDistance: "100%" }],
        { duration: dur * 1000, delay: -(i * dur / 3) * 1000, iterations: Infinity, easing: "linear" }
      )
    }
  }

  _efLine(targetName, color) {
    const el = this[targetName]
    if (el) el.setAttribute("stroke", color)
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

// Connects to data-controller="light-detail". Drives the lamp detail page:
// power, brightness, colour-temperature (Weiß) and colour swatches (Farbe).
// Optimistic send + reconcile against DashboardChannel { lights:[...] }.
import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

export default class extends Controller {
  static values = { key: String, tab: String, maxZones: Number }
  static targets = ["panel", "brightness", "temp", "wheel", "error", "lamp", "toast", "toastMsg"]

  connect() {
    this.showTab(this.tabValue || "white")
    this.subscription = consumer.subscriptions.create("DashboardChannel", {
      received: (data) => this.onBroadcast(data),
    })
  }

  disconnect() { this.subscription?.unsubscribe() }

  // --- tabs ---
  tab(event) { this.showTab(event.params.tab) }

  showTab(name) {
    this.tabValue = name
    this.panelTargets.forEach((p) => { p.hidden = p.dataset.tab !== name })
    this.element.querySelectorAll(".ld-tab").forEach((b) => {
      b.classList.toggle("active", b.dataset.lightDetailTabParam === name)
    })
  }

  // --- commands ---
  on() { this.send({ command: "turn", on: "true" }) }
  off() { this.send({ command: "turn", on: "false" }) }

  brightness(event) {
    this.debounce(() => this.send({ command: "brightness", value: event.target.value }))
  }

  temp(event) {
    const k = event.params.temp ?? event.target.value
    if (this.hasTempTarget && event.params.temp) this.tempTarget.value = k
    this.debounce(() => this.send({ command: "color_temp", temp_k: k }))
  }

  swatch(event) { this.applyHex(event.params.color) }
  wheel(event) { this.applyHex(event.target.value) }

  applyHex(hex) {
    const r = parseInt(hex.slice(1, 3), 16)
    const g = parseInt(hex.slice(3, 5), 16)
    const b = parseInt(hex.slice(5, 7), 16)
    this.debounce(() => this.send({ command: "color", r, g, b }))
  }

  // --- scenes & moods ---
  mood(event) {
    this.selectScene(event.currentTarget)
    this.send({ command: "mood", mood: event.params.mood })
  }

  scene(event) {
    this.selectScene(event.currentTarget)
    this.send({ command: "effect", effect: event.params.scene })
  }

  selectScene(btn) {
    this.element.querySelectorAll(".ld-scene.sel").forEach((b) => b.classList.remove("sel"))
    btn.classList.add("sel")
  }

  // --- zones ---
  zone(event) {
    const key = event.params.zone
    const role = event.params.role
    const card = this.zoneCard(key)
    if (!card) return
    const turningOn = card.classList.contains("off")

    if (turningOn && role === "side" && this.maxZonesValue > 0) {
      const onCards = this.onZoneCards()
      if (onCards.length >= this.maxZonesValue) {
        const victim = this.victimSideCard(card)
        if (victim) {
          this.setZoneCard(victim, false)
          this.send({ command: "zone", zone: victim.dataset.zoneKey, on: "false" })
          this._undo = { victimKey: victim.dataset.zoneKey, newKey: key }
          this.showToast(`${this.zoneLabel(victim)} ausgeschaltet · max. ${this.maxZonesValue} Zonen`)
        }
      }
    }

    this.setZoneCard(card, turningOn)
    if (turningOn && role === "side") this._lastSide = key
    this.send({ command: "zone", zone: key, on: String(turningOn) })
  }

  undoZone() {
    if (!this._undo) return this.hideToast()
    const victim = this.zoneCard(this._undo.victimKey)
    const added = this.zoneCard(this._undo.newKey)
    if (victim) { this.setZoneCard(victim, true);  this.send({ command: "zone", zone: this._undo.victimKey, on: "true" }) }
    if (added)  { this.setZoneCard(added, false);  this.send({ command: "zone", zone: this._undo.newKey, on: "false" }) }
    this._lastSide = this._undo.victimKey
    this._undo = null
    this.hideToast()
  }

  // zone helpers
  zoneCard(key) { return this.element.querySelector(`.ld-zone[data-zone-key="${key}"]`) }
  zoneLabel(card) { return card.querySelector(".ld-zone-nm")?.textContent ?? "Zone" }
  onZoneCards() { return [...this.element.querySelectorAll(".ld-zone:not(.off)")] }

  victimSideCard(exclude) {
    const sides = this.onZoneCards().filter((c) => c.dataset.zoneRole === "side" && c !== exclude)
    const last = this._lastSide && sides.find((c) => c.dataset.zoneKey === this._lastSide)
    return last || sides[0] || null
  }

  setZoneCard(card, on) {
    card.classList.toggle("off", !on)
    card.querySelector(".ld-zone-toggle")?.classList.toggle("on", on)
  }

  showToast(msg) {
    if (!this.hasToastTarget) return
    if (this.hasToastMsgTarget) this.toastMsgTarget.textContent = msg
    this.toastTarget.hidden = false
    clearTimeout(this._toastTimer)
    this._toastTimer = setTimeout(() => this.hideToast(), 5000)
  }

  hideToast() {
    clearTimeout(this._toastTimer)
    this._undo = null
    if (this.hasToastTarget) this.toastTarget.hidden = true
  }

  // --- plumbing ---
  debounce(fn) { clearTimeout(this._d); this._d = setTimeout(fn, 250) }

  send(body) {
    this.element.classList.add("pending")
    fetch(`/lights/${this.keyValue}/command`, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
      },
      body: new URLSearchParams(body).toString(),
    })
    clearTimeout(this._timeout)
    this._timeout = setTimeout(() => this.unconfirmed(), 5000)
  }

  onBroadcast(data) {
    if (!Array.isArray(data.lights)) return
    const light = data.lights.find((l) => l.light_key === this.keyValue)
    if (!light) return
    clearTimeout(this._timeout)
    this.element.classList.remove("pending", "unconfirmed")
    if (this.hasErrorTarget) this.errorTarget.textContent = ""
    if (this.hasLampTarget) this.lampTarget.classList.toggle("off", light.on === false)
    this.element.querySelectorAll(".ld-pill").forEach((b) => {
      const wantsOn = b.dataset.action?.includes("#on") ?? false
      b.classList.toggle("on", wantsOn === (light.on === true))
    })
    if (typeof light.brightness === "number" && this.hasBrightnessTarget) {
      this.brightnessTarget.value = light.brightness
    }
    if (typeof light.color_temp_k === "number" && this.hasTempTarget) {
      this.tempTarget.value = light.color_temp_k
    }
    if (light.zones && typeof light.zones === "object") {
      for (const [key, on] of Object.entries(light.zones)) {
        const card = this.zoneCard(key)
        if (card) this.setZoneCard(card, on === true)
      }
    }
  }

  unconfirmed() {
    this.element.classList.remove("pending")
    this.element.classList.add("unconfirmed")
    if (this.hasErrorTarget) this.errorTarget.textContent = "Nicht bestätigt"
  }
}

// Connects to data-controller="light-detail". Drives the lamp detail page:
// power, brightness, colour-temperature (Weiß) and colour swatches (Farbe).
// Optimistic send + reconcile against DashboardChannel { lights:[...] }.
import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

export default class extends Controller {
  static values = { key: String, tab: String }
  static targets = ["panel", "brightness", "temp", "wheel", "error", "lamp"]

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
    this.element.classList.toggle("is-off", light.on === false)
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
  }

  unconfirmed() {
    this.element.classList.remove("pending")
    this.element.classList.add("unconfirmed")
    if (this.hasErrorTarget) this.errorTarget.textContent = "Nicht bestätigt"
  }
}

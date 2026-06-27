// Connects to data-controller="light-detail". Slim: tab switching + debounced
// fire-and-forget sliders/wheel. Zone/power/toast state is server-rendered via
// Turbo Streams (see lights/_zone, _power, _toast partials).
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { key: String, tab: String }
  static targets = ["panel", "temp"]

  connect() { this.showTab(this.tabValue || "white") }

  tab(event) { this.showTab(event.params.tab) }

  showTab(name) {
    this.tabValue = name
    this.panelTargets.forEach((p) => { p.hidden = p.dataset.tab !== name })
    this.element.querySelectorAll(".ld-tab").forEach((b) => {
      b.classList.toggle("active", b.dataset.lightDetailTabParam === name)
    })
  }

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

  debounce(fn) { clearTimeout(this._d); this._d = setTimeout(fn, 250) }

  send(body) {
    fetch(`/lights/${this.keyValue}/command`, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
      },
      body: new URLSearchParams(body).toString(),
    })
  }
}

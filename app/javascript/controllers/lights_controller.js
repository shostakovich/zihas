// app/javascript/controllers/lights_controller.js
import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

// Connects to data-controller="lights". Sends Govee commands optimistically
// (card shows .pending) and reconciles to the confirmed state from the
// "dashboard" ActionCable broadcasts ({ lights: [...] }) produced by
// GoveeStatusHandler.
export default class extends Controller {
  connect() {
    this.timeouts = {}
    this.debounces = {}
    this.subscription = consumer.subscriptions.create("DashboardChannel", {
      received: (data) => this.handleBroadcast(data),
    })
  }

  disconnect() {
    this.subscription?.unsubscribe()
  }

  toggle(event) {
    const key = event.params.key
    const card = this.cardFor(key)
    if (!card) return
    const on = !card.querySelector("button.sw-knob").classList.contains("off")
    this.send(key, { command: "turn", on: (!on).toString() })
  }

  brightness(event) {
    const key = event.params.key
    const value = event.target.value
    this.debounced(key, () => this.send(key, { command: "brightness", value }))
  }

  color(event) {
    const key = event.params.key
    const hex = event.target.value // #rrggbb
    const r = parseInt(hex.slice(1, 3), 16)
    const g = parseInt(hex.slice(3, 5), 16)
    const b = parseInt(hex.slice(5, 7), 16)
    this.debounced(key, () => this.send(key, { command: "color", r, g, b }))
  }

  debounced(key, fn) {
    clearTimeout(this.debounces[key])
    this.debounces[key] = setTimeout(fn, 250)
  }

  send(key, body) {
    const card = this.cardFor(key)
    if (card) card.classList.add("pending")
    const params = new URLSearchParams(body)
    fetch(`/lights/${key}/command`, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
      },
      body: params.toString(),
    })
    clearTimeout(this.timeouts[key])
    this.timeouts[key] = setTimeout(() => this.markUnconfirmed(key), 5000)
  }

  handleBroadcast(data) {
    if (!Array.isArray(data.lights)) return
    data.lights.forEach((light) => this.applyState(light))
  }

  applyState(light) {
    const card = this.cardFor(light.light_key)
    if (!card) return
    clearTimeout(this.timeouts[light.light_key])
    card.classList.remove("pending", "unconfirmed")

    if (typeof light.on === "boolean") {
      const knob = card.querySelector("button.sw-knob")
      if (knob) knob.classList.toggle("off", !light.on)
    }
    if (typeof light.brightness === "number") {
      const slider = card.querySelector('input[type="range"]')
      if (slider) slider.value = light.brightness
    }
    const error = card.querySelector(".sw-error")
    if (error) error.textContent = ""
  }

  markUnconfirmed(key) {
    const card = this.cardFor(key)
    if (!card) return
    card.classList.remove("pending")
    card.classList.add("unconfirmed")
    const error = card.querySelector(".sw-error")
    if (error) error.textContent = "Nicht bestätigt"
  }

  cardFor(key) {
    return this.element.querySelector(`[data-light-key="${key}"]`)
  }
}

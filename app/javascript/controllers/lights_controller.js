// Connects to data-controller="lights" on the Schalten list. Only the plush
// knob toggles power here; brightness/colour live on the lamp detail page.
// Optimistic toggle, reconciled by DashboardChannel { lights:[...] }.
import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

export default class extends Controller {
  connect() {
    this.timeouts = {}
    this.subscription = consumer.subscriptions.create("DashboardChannel", {
      received: (data) => this.handleBroadcast(data),
    })
  }

  disconnect() { this.subscription?.unsubscribe() }

  toggle(event) {
    event.preventDefault()
    const key = event.params.key
    const card = this.cardFor(key)
    if (!card) return
    const on = !card.querySelector("button.sw-knob").classList.contains("off")
    this.send(key, { command: "turn", on: (!on).toString() })
  }

  send(key, body) {
    const card = this.cardFor(key)
    if (card) card.classList.add("pending")
    fetch(`/lights/${key}/command`, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
      },
      body: new URLSearchParams(body).toString(),
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

  cardFor(key) { return this.element.querySelector(`[data-light-key="${key}"]`) }
}

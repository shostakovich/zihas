import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

// Connects to data-controller="switches" on the Schalten tab.
// Applies live wattage and output state from the existing "dashboard"
// ActionCable broadcasts (see MqttSubscriber) to the plug cards.
export default class extends Controller {
  connect() {
    this.subscription = consumer.subscriptions.create("DashboardChannel", {
      received: (data) => this.handleBroadcast(data),
    })
  }

  disconnect() {
    this.subscription?.unsubscribe()
  }

  handleBroadcast(data) {
    if (!Array.isArray(data.plugs)) return
    data.plugs.forEach((plug) => this.updateCard(plug))
  }

  updateCard(plug) {
    const card = this.element.querySelector(`[data-plug-id="${plug.plug_id}"]`)
    if (!card) return

    const watt = card.querySelector(`[data-switches-watt="${plug.plug_id}"]`)
    if (watt && typeof plug.apower_w === "number") {
      watt.textContent = `· ${Math.round(plug.apower_w)} W`
    }

    if (typeof plug.output === "boolean") {
      const toggle = card.querySelector("button.sw-toggle")
      if (toggle) {
        toggle.classList.toggle("off", !plug.output)
        toggle.disabled = false
        // Keep the form posting the opposite of the confirmed state.
        const form = toggle.closest("form")
        if (form) form.action = form.action.replace(/state=(on|off)/, `state=${plug.output ? "off" : "on"}`)
        // Authoritative state arrived — clear any stale error.
        const error = card.querySelector(".sw-error")
        if (error) error.textContent = ""
      }
      card.classList.remove("sw-offline")
    }
  }
}

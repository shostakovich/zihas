// Connects to data-controller="toast". Auto-dismisses the toast after 5s by
// hiding it. The undo button inside is a server-driven button_to form.
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    if (this.element.hidden) return
    this._t = setTimeout(() => { this.element.hidden = true }, 5000)
  }

  disconnect() { clearTimeout(this._t) }
}

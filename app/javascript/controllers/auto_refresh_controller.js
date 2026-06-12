import { Controller } from "@hotwired/stimulus"

// Periodically reloads the page while this element stays mounted — used by the
// dashboard's "live" view during an active scrape.
//
// Why not <meta http-equiv="refresh">: with Turbo Drive that tag lingers in the
// cached page snapshot and the browser's refresh timer survives Turbo's soft
// navigations, so after you click into another page it can fire and bounce you
// back to the dashboard. A Stimulus timer is cleared on disconnect() (which Turbo
// calls when you navigate away or before caching), so it never fires off-page.
export default class extends Controller {
  static values = { interval: { type: Number, default: 4000 } }

  connect() {
    this.timer = setTimeout(() => {
      window.Turbo.visit(window.location.href, { action: "replace" })
    }, this.intervalValue)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}

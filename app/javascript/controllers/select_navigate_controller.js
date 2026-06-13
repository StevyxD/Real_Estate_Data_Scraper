import { Controller } from "@hotwired/stimulus"

// Navigates to the selected <option>'s value (a URL) on change — used by the
// project-number "Jump to group" dropdown so it works without a submit button.
export default class extends Controller {
  go(event) {
    const url = event.target.value
    if (url) window.Turbo.visit(url, { action: "advance" })
  }
}

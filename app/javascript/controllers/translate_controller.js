import { Controller } from "@hotwired/stimulus"

// Toggles Google Translate between English (default) and native Marathi.
// The widget treats the page source as Marathi (pageLanguage: "mr"), so:
//   /mr/en -> the Marathi data is translated to English (UI stays English)
//   /mr/mr -> the original Marathi data (no translation)
// The server sets /mr/en on first visit (ApplicationController), so English is
// the default. We keep the cookie present (never empty) so that default doesn't
// re-trigger after the user explicitly chooses Marathi.
export default class extends Controller {
  static targets = ["label"]

  connect() {
    this.render()
  }

  toggle() {
    const next = this.current === "en" ? "mr" : "en"
    this.setCookie(`/mr/${next}`)
    window.location.reload()
  }

  get current() {
    const match = document.cookie.match(/googtrans=\/mr\/([a-z]+)/i)
    return match ? match[1].toLowerCase() : "en"
  }

  setCookie(value) {
    document.cookie = `googtrans=${value}; path=/`
    document.cookie = `googtrans=${value}; path=/; domain=${location.hostname}`
  }

  // Button shows the language you'll switch TO.
  render() {
    if (this.hasLabelTarget) {
      this.labelTarget.textContent = this.current === "en" ? "मराठी" : "English"
    }
  }
}

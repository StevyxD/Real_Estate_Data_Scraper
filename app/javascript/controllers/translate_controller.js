import { Controller } from "@hotwired/stimulus"

// Toggles Google Translate between English (default) and Marathi by setting the
// `googtrans` cookie and reloading. English = no cookie (original page); Marathi
// = "/en/mr". The hidden Google widget (in the layout) applies the cookie on load.
export default class extends Controller {
  static targets = ["label"]

  connect() {
    this.render()
  }

  toggle() {
    if (this.current === "mr") {
      this.clearCookie()
    } else {
      this.setCookie("/en/mr")
    }
    window.location.reload()
  }

  get current() {
    const match = document.cookie.match(/(?:^|;\s*)googtrans=\/[^/]*\/([a-z-]+)/i)
    return match ? match[1].toLowerCase() : "en"
  }

  setCookie(value) {
    document.cookie = `googtrans=${value}; path=/`
    document.cookie = `googtrans=${value}; path=/; domain=${location.hostname}`
  }

  clearCookie() {
    const expired = "expires=Thu, 01 Jan 1970 00:00:00 GMT"
    document.cookie = `googtrans=; path=/; ${expired}`
    document.cookie = `googtrans=; path=/; domain=${location.hostname}; ${expired}`
  }

  // Button shows the language you'll switch TO.
  render() {
    if (this.hasLabelTarget) {
      this.labelTarget.textContent = this.current === "mr" ? "English" : "मराठी"
    }
  }
}

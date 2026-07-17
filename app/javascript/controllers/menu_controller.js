import { Controller } from "@hotwired/stimulus"

// Disclosure menu (WAI-ARIA disclosure navigation pattern): a button that
// shows/hides a panel of links or buttons, with keyboard and outside-click
// dismissal.
export default class extends Controller {
  static targets = [ "button", "panel" ]

  connect() {
    this.close = this.close.bind(this)
    this.closeOnOutsideClick = this.closeOnOutsideClick.bind(this)
  }

  disconnect() {
    this.#teardown()
  }

  toggle() {
    this.expanded ? this.close() : this.open()
  }

  open() {
    this.buttonTarget.setAttribute("aria-expanded", "true")
    this.panelTarget.hidden = false
    document.addEventListener("click", this.closeOnOutsideClick)
  }

  close() {
    if (!this.expanded) return

    this.buttonTarget.setAttribute("aria-expanded", "false")
    this.panelTarget.hidden = true
    this.#teardown()
  }

  closeAndFocus(event) {
    if (!this.expanded) return

    event.stopPropagation()
    this.close()
    this.buttonTarget.focus()
  }

  closeOnFocusOut(event) {
    if (event.relatedTarget && !this.element.contains(event.relatedTarget)) this.close()
  }

  closeOnOutsideClick(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  moveDown(event) {
    this.#moveFocus(event, 1)
  }

  moveUp(event) {
    this.#moveFocus(event, -1)
  }

  get expanded() {
    return this.buttonTarget.getAttribute("aria-expanded") === "true"
  }

  #moveFocus(event, offset) {
    if (!this.expanded) {
      if (event.target === this.buttonTarget && offset === 1) {
        event.preventDefault()
        this.open()
        this.#items[0]?.focus()
      }
      return
    }

    event.preventDefault()
    const items = this.#items
    const index = items.indexOf(document.activeElement)
    const next = index === -1 ? 0 : (index + offset + items.length) % items.length
    items[next]?.focus()
  }

  get #items() {
    return Array.from(this.panelTarget.querySelectorAll("a, button"))
  }

  #teardown() {
    document.removeEventListener("click", this.closeOnOutsideClick)
  }
}

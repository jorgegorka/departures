import { Controller } from "@hotwired/stimulus"

// Opens the inspector <dialog> when its turbo-frame loads content.
export default class extends Controller {
  static targets = [ "dialog", "frame" ]

  open() {
    if (!this.dialogTarget.open) this.dialogTarget.showModal()
  }

  close() {
    this.dialogTarget.close()
    this.frameTarget.removeAttribute("src")
    this.frameTarget.innerHTML = ""
  }
}

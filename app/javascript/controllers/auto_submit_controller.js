import { Controller } from "@hotwired/stimulus"

// Submits the surrounding form whenever a control changes.
export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }
}

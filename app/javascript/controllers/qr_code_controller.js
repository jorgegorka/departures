import { Controller } from "@hotwired/stimulus"
import qrcode from "qrcode-generator"

// Renders the value of data-qr-code-text-value as an inline SVG QR code.
export default class extends Controller {
  static values = { text: String }

  connect() {
    const qr = qrcode(0, "M")
    qr.addData(this.textValue)
    qr.make()
    this.element.innerHTML = qr.createSvgTag({ cellSize: 4, margin: 2, scalable: true })
  }
}

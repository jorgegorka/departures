import { Controller } from "@hotwired/stimulus"
import {
  Chart, LineController, LineElement, PointElement,
  CategoryScale, LinearScale, Filler, Tooltip, Legend
} from "chart.js"

Chart.register(LineController, LineElement, PointElement, CategoryScale, LinearScale, Filler, Tooltip, Legend)

// Renders a time-series line chart from a non-executable JSON payload:
//   { labels: [...], datasets: [{ label, data, role }] }
// Dataset roles map to CSS tokens so charts follow the active theme.
export default class extends Controller {
  static targets = [ "canvas", "data" ]

  connect() {
    const { labels, datasets } = JSON.parse(this.dataTarget.textContent)
    const styles = getComputedStyle(this.element)
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches

    this.chart = new Chart(this.canvasTarget, {
      type: "line",
      data: { labels, datasets: datasets.map((dataset) => this.styled(dataset, styles)) },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: reducedMotion ? false : { duration: 300 },
        interaction: { mode: "index", intersect: false },
        plugins: {
          legend: {
            display: datasets.length > 1,
            position: "top",
            align: "end",
            labels: { boxWidth: 8, boxHeight: 8, usePointStyle: true, color: styles.getPropertyValue("--color-ink-light") }
          },
          tooltip: {
            backgroundColor: styles.getPropertyValue("--color-ink"),
            titleColor: styles.getPropertyValue("--color-ink-inverted"),
            bodyColor: styles.getPropertyValue("--color-ink-inverted"),
            padding: 8,
            boxWidth: 8,
            boxHeight: 8,
            usePointStyle: true
          }
        },
        scales: {
          x: {
            grid: { display: false },
            border: { color: styles.getPropertyValue("--color-border-strong") },
            ticks: { color: styles.getPropertyValue("--color-ink-lighter"), maxTicksLimit: 8, maxRotation: 0 }
          },
          y: {
            beginAtZero: true,
            border: { display: false },
            grid: { color: styles.getPropertyValue("--color-border") },
            ticks: { color: styles.getPropertyValue("--color-ink-lighter"), precision: 0, maxTicksLimit: 5 }
          }
        }
      }
    })
  }

  disconnect() {
    this.chart?.destroy()
    this.chart = null
  }

  styled({ label, data, role }, styles) {
    const color = styles.getPropertyValue(`--chart-${role || "neutral"}`).trim()

    return {
      label, data,
      borderColor: color,
      backgroundColor: this.withAlpha(color, 0.08),
      fill: "origin",
      borderWidth: 2,
      tension: 0.25,
      pointRadius: 0,
      pointHoverRadius: 3,
      pointHitRadius: 12,
      pointBackgroundColor: color
    }
  }

  withAlpha(color, alpha) {
    return `color-mix(in oklab, ${color} ${alpha * 100}%, transparent)`
  }
}

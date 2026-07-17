# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin "qrcode-generator" # @2.0.4
pin "chart.js" # @4.5.1, vendored from the npm package (dist/chart.js + its chunk)
pin "@kurkle/color", to: "@kurkle--color.js" # @0.3.4
# chart.js imports its helpers chunk with a relative path; a URL-keyed pin
# resolves that request to the digested asset.
pin "/assets/chunks/helpers.dataset.js", to: "chunks/helpers.dataset.js"

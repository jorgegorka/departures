# First deploy

The one-time runbook the operator follows to bring Departures up in production
with Kamal. Everything here is driven from the dev machine unless it says "on
the host". Work through the sections in order; the production details
(`<VPS_IP>`, `<APP_DOMAIN>`, ghcr PAT, ops SES credentials) must exist before
you start.

## Prerequisites

1. **DNS**: an A record for `<APP_DOMAIN>` → `<VPS_IP>`, already propagated
   (`dig +short <APP_DOMAIN>` returns the VPS IP). kamal-proxy needs this
   resolving before it can obtain a Let's Encrypt certificate.
2. **VPS**: Docker installed and running; ports **80** and **443** open to the
   world (Let's Encrypt HTTP-01 challenge + HTTPS traffic).
3. **Replace the placeholders** — these are literal `<...>` strings in the repo
   and must be swapped for real values and committed before the first deploy:
   - `config/deploy.yml`: `<VPS_IP>` (both the `web` and `job` server entries)
     and `<APP_DOMAIN>` (the `proxy.host`).
   - `config/environments/production.rb`: the mailer host, currently
     `config.action_mailer.default_url_options = { host: "example.com" }` —
     set it to `<APP_DOMAIN>` so links in transactional mail resolve.
4. **Registry credential**: export a GitHub Container Registry PAT with the
   `write:packages` scope so Kamal can push the built image to
   `ghcr.io/jorgegorka/departures`:

       export KAMAL_REGISTRY_PASSWORD=<ghcr PAT>

5. **`.kamal/secrets`**: this file is **git-ignored** (never committed — it can
   reference credentials) and must exist locally with its two env-passthrough
   lines:

       KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD
       RAILS_MASTER_KEY=$(cat config/master.key)

   The first line forwards the PAT you exported above; the second reads the
   Rails master key that decrypts credentials inside the container.
6. **Ops credentials**: add the `ops:` block to Rails credentials so
   `Ops::ErrorNotifier` can send alert email (if the block is absent the
   notifier is silent):

       bin/rails credentials:edit

   The exact keys under `ops:` are documented in `docs/ops/monitoring.md`.

## First deploy

From the dev machine, with `KAMAL_REGISTRY_PASSWORD` exported:

    bin/kamal setup

Expected: image builds (amd64), pushes to ghcr.io, kamal-proxy boots with a
Let's Encrypt cert, and the web + job containers come up healthy.

## Verification checklist

Record each result.

- [ ] 1. `curl -s -o /dev/null -w "%{http_code}" https://<APP_DOMAIN>/up` → `200`;
      certificate valid in the browser.
- [ ] 2. `curl -s -o /dev/null -w "%{http_code}" http://<APP_DOMAIN>/` → `301`
      redirect to https (`force_ssl` live). Response headers include
      `Strict-Transport-Security` and `Content-Security-Policy`.
- [ ] 3. Register the first user (registration is open while `User.none?`),
      complete onboarding: workspace → source (live SES credentials) → domain →
      API key.
- [ ] 4. Real send: `POST https://<APP_DOMAIN>/api/emails` with the API key →
      202, message arrives in a real inbox with the `X-Departures-Id` header.
- [ ] 5. SNS wiring: in the AWS console, point the SES configuration-set event
      destination / SNS subscription at
      `https://<APP_DOMAIN>/api/webhooks/ses/<webhook_token>` (token from the
      source page). The `SubscriptionConfirmation` auto-confirms (subscription
      shows Confirmed); the delivery event for the test send lands — email
      status advances and the activity dashboard updates live in a second
      browser window.
- [ ] 6. Job role healthy: `bin/kamal logs -r job` shows Solid Queue polling and
      the send job processed.
- [ ] 7. Error notifier: from `bin/kamal console`, run
      `Ops::ErrorNotifier.new.report(RuntimeError.new("phase 9 alert test"), handled: false, severity: :error)`
      → alert email arrives at the ops `to:` address.
- [ ] 8. Uptime monitor created against `https://<APP_DOMAIN>/up` and showing Up
      (see `docs/ops/monitoring.md`).

## Backup setup + restore drill

Follow the one-time setup in `docs/ops/backup-and-restore.md`, run the script
manually, confirm the snapshot with `rclone ls`, then run the restore drill
(download + `PRAGMA integrity_check` → `ok`, spot-check
`SELECT count(*) FROM emails;`). Record the outputs in the phase-close notes.

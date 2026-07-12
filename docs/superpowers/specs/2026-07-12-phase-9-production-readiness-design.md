# Phase 9 — Production Readiness: Design

**Date:** 2026-07-12
**Status:** Approved design, pending implementation plan
**Prerequisites:** Phases 0–8 complete and merged to `master`.

## Goal

Turn the finished Departures build into a running production service: deploy to
Jorge's existing VPS with Kamal, terminate SSL, enable the security headers
deferred from Phase 8, back up the data nightly, alert on errors, and clear the
Phase 8 post-merge follow-up list.

## Decisions made during brainstorming

| Decision | Choice |
|---|---|
| Deployment target | Existing VPS (single host, web + job roles) |
| SSL / DNS | DNS A record → VPS; kamal-proxy with Let's Encrypt |
| Container registry | GitHub Container Registry (`ghcr.io/jorgegorka`) |
| Backups | Nightly host-cron snapshot to S3-compatible object storage |
| Backup runner | Host-level cron script (not an in-app job) |
| Monitoring | External uptime ping on `/up` + in-app error notifier |
| Error alert transport | Email via a dedicated ops SES client (accepted trade-off: a total SES outage also silences alerts) |
| Phase 8 follow-ups | Folded into this phase |

Global constraints still apply: no new gems, Minitest + fixtures,
`bin/rails test` and `bin/rubocop` green at the end of every task.

## 1. Kamal deployment

Fill in `config/deploy.yml` with real values:

- `servers.web` and `servers.job.hosts`: the VPS IP (committed — normal Kamal
  practice). `job` keeps `cmd: bin/jobs`.
- `proxy: { ssl: true, host: <app domain> }` — kamal-proxy auto-provisions the
  Let's Encrypt certificate.
- `registry: { server: ghcr.io, username: jorgegorka, password: [KAMAL_REGISTRY_PASSWORD] }`.
  The ghcr personal access token and `RAILS_MASTER_KEY` live in `.kamal/secrets`
  (git-ignored; sourced from 1Password/env per Kamal convention).
- Existing `departures_storage:/rails/storage` volume unchanged — it holds all
  four SQLite databases and the archived `.eml` files.
- `builder.arch: amd64` unchanged.

**Concrete values needed at execution time:** VPS IP, app domain, ghcr PAT.

### Deploy verification checklist (manual, part of the phase)

1. `kamal setup` succeeds; `/up` returns 200 over HTTPS with a valid certificate.
2. HTTP requests redirect to HTTPS (`force_ssl` live).
3. First-user registration works (registration gate: `User.none?`).
4. A real send: onboard a source with live SES credentials, `POST /api/emails`,
   message received.
5. SES event destination / SNS subscription pointed at
   `https://<domain>/api/webhooks/ses/<webhook_token>`; SNS
   `SubscriptionConfirmation` auto-confirmed; a delivery event lands and the
   activity dashboard updates live.
6. Job role healthy: Solid Queue processing on the `job` container
   (`kamal app logs -r job`).

## 2. force_ssl + Content-Security-Policy (deferred from Phase 8)

In `config/environments/production.rb`:

- `config.assume_ssl = true`
- `config.force_ssl = true`

CSP via `config/initializers/content_security_policy.rb`:

- `default-src 'self'`
- `script-src 'self'` with per-request nonces (importmap-compatible; the
  importmap JSON tag and any inline module tags get the nonce)
- `style-src 'self'` (all CSS is hand-written files; no inline styles expected —
  if a Turbo/vendored need for inline style surfaces during implementation, add
  a style nonce rather than `unsafe-inline`)
- `img-src 'self' data:` (mask-based `icon_tag` icons are same-origin SVG)
- `font-src 'self'`, `object-src 'none'`, `frame-ancestors 'none'`,
  `base-uri 'self'`, `form-action 'self'`
- `connect-src 'self'` (Turbo Streams / Action Cable are same-origin)

**Carve-out:** the email preview endpoint (`emails#preview`) already sets its
own stricter per-response CSP (`default-src 'none'; img-src * data:`). That
response-level header remains authoritative for that action. A test asserts the
preview response still carries its own policy and dashboard responses carry the
global one. The preview iframe itself must still render under the parent page's
`frame-src` — `frame-src 'self'` is included since the iframe src is same-origin.

CSP ships in enforcing mode (not report-only): the app has no third-party
assets, so the surface is small and verifiable in development before deploy.

## 3. Backups (host cron)

A `bin/backup` bash script, versioned in the repo, executed on the **host** by
root cron nightly (not inside the container, not a Solid Queue job):

1. For `production.sqlite3` and `queue.sqlite3` on the Docker volume: run
   `sqlite3 <db> ".backup <snapshot>"` (safe, consistent online backup).
   `cache` and `cable` databases are disposable — recreated on boot, not backed up.
2. `tar` the `storage/emails/` tree (archived `.eml` files).
3. Upload both to an S3-compatible bucket via `rclone` (installed on the host).
4. Prune remote snapshots older than 30 days.
5. On any step failing, the script exits non-zero and cron mails root /
   logs; the uptime + error-notifier layers are not involved (host-level concern).

Companion doc `docs/ops/backup-and-restore.md` covers: rclone remote setup, the
crontab line, snapshot layout/retention, and the **restore procedure** —
download snapshot, `PRAGMA integrity_check`, stop app, swap files, restart.

**Phase close includes a restore drill:** restore the previous night's snapshot
to a scratch directory and verify `PRAGMA integrity_check` returns `ok` plus a
spot-check row count.

## 4. Monitoring and error alerts

### Uptime

External monitor (UptimeRobot free tier or equivalent) pinging
`https://<domain>/up` every 5 minutes. Documented setup step in a short `docs/ops/monitoring.md`;
nothing in app code.

### Error notifier

- `Ops::ErrorNotifier` — plain Ruby class (presenter shape, patterns §3.4) in
  `app/models/ops/error_notifier.rb`.
- Subscribed in `config/initializers/error_reporting.rb` via
  `Rails.error.subscribe` (production only). This captures unhandled request
  errors and job errors surfaced through the Rails error-reporting interface;
  implementation verifies Solid Queue's failed executions actually flow through
  it and adds an explicit hook if they don't.
- On report: build a small plain-text email with the `mail` gem (already
  present) — error class, message, first backtrace lines, context — and send
  via its own memoized `Aws::SESV2::Client`.
- **Credentials:** dedicated ops SES credentials + from/to addresses under
  `Rails.application.credentials.ops` (`aws_access_key_id`,
  `aws_secret_access_key`, `region`, `from`, `to`). Deliberately NOT a tenant
  `Source` — ops alerting stays decoupled from tenant data. If credentials are
  absent (development/test), the notifier no-ops.
- **Dedup/throttle:** Solid Cache key per error class, 10-minute TTL — at most
  one alert per error class per 10 minutes. A hot failure loop cannot flood the
  inbox or damage SES reputation.
- The notifier must never raise (a broken notifier must not mask or amplify the
  original error): all internal failures rescued and logged.

## 5. Phase 8 post-merge follow-ups

1. Already-enrolled guard on `Users::TwoFactorsController#new` / `#create`
   (redirect enrolled users away from re-enrollment).
2. Drop unused `:subject` from `AuditEvent.preloaded`.
3. Audit-row assertions for the 5 actions currently uncovered by tests.
4. Test wiring audit-event 180-day pruning into `PruneRetentionJob`.

## 6. Testing

- `Ops::ErrorNotifier`: unit tests with stubbed `Aws::SESV2::Client`
  (`stub_responses: true`, matching existing convention) — sends on first
  report, throttles the second within 10 minutes, no-ops without credentials,
  never raises when SES errors.
- CSP: integration tests asserting the global policy header on a dashboard
  response and the stricter per-response policy on `emails#preview`.
- Follow-up items each land with their tests (guard redirect, audit coverage,
  prune wiring).
- `force_ssl` stays off in development/test; correctness is covered by the
  manual deploy checklist (HTTP→HTTPS redirect).
- Phase ends green: `bin/rails test`, `bin/rubocop`, plus the manual deploy
  checklist and restore drill signed off.

## Out of scope

- Litestream / continuous replication (declined — nightly RPO accepted).
- Third-party APM or error trackers (no new gems).
- Multi-host / load-balanced topology.
- New product features (candidates like batch send, template versioning stay
  on the backlog).

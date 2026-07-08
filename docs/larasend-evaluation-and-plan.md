# Larasend Evaluation → Rails "Departures" Roadmap

## Context

We want to build a self-hosted transactional email platform (send via Amazon SES, track activity/events, manage API keys and suppressions) into the blank Rails 8.1 app at `~/Sites/rails/departures`. Before designing anything, we evaluated https://github.com/savvyagents/larasend (Laravel/Inertia/Vue/PostgreSQL/Redis) to catalog its features, structure, multi-tenancy and permission model. The clone used for analysis lives in the session scratchpad (`.../scratchpad/larasend`).

## What Larasend Is

A self-hosted control plane for SES: client apps send mail through a simple `POST /api/emails` HTTP API (or a drop-in Laravel mail driver); Larasend stores the full MIME message, queues delivery through SES v2 raw send, ingests SES/SNS delivery events (delivery/bounce/complaint/open/click), maintains suppression lists, relays events to customer webhooks, and shows everything in an activity dashboard.

## Domain Model (14 tables)

Hierarchy: **Workspace → Project → {Source, Domain, ApiKey, Template, WebhookEndpoint, Email, Suppression}**; **Email → {EmailRecipient, EmailAttachment, EmailEvent}**; **WebhookEndpoint → WebhookDelivery**; plus **WebhookLog** (raw inbound SNS payloads) and **workspace_user** membership pivot with a `role` column.

Key entities:
- **Workspace** — owner_id, name, slug, onboarded_at. Holds the role→capability map.
- **Project** — the tenant unit for email data; archivable (`archived_at`); deletable only when empty.
- **Source** — the SES sending identity per project+environment (unique pair): region, configuration set, default from, encrypted AWS keys (or EC2 instance role in prod), unique `webhook_token` (the inbound SNS URL secret), quota cache (`last_quota`, `last_quota_checked_at`).
- **Domain** — sending domain with status (pending/verified) and stored DKIM CNAME records.
- **ApiKey** — `ls_` + 48 chars, stored as sha256 hash + 12-char prefix; scopes (`send`, `read:activity`), expiry, rotation, last-used at/IP/UA telemetry; plaintext shown once.
- **Email** — public_id, status state machine, from/subject/html/text, headers/tags JSON, `ses_message_id`; full MIME written to disk (`emails/{project}/{public_id}.eml`), only path/size in DB. Indexed `(project_id, status, created_at)`.
- **EmailEvent** — one row per SES event with recipient, url/UA/IP (opens/clicks), full payload, occurred_at.
- **Suppression** — unique `(project_id, email)`, reason (`complaint` / `hard_bounce`), optional expires_at.
- **WebhookEndpoint/Delivery** — customer relay endpoints with encrypted `whsec_` signing secret, event subscriptions, per-delivery log (http status, latency, response body).
- **Template** — slug, subject/html/text with `{{ var }}` substitution.

## Send Pipeline

1. `POST /api/emails` → bearer API key middleware (sha256 lookup, scope + expiry check, tenant derived from the key) → validation (from/to/cc/bcc up to 1000 each, subject OR template_id, html/text, ≤25 attachments base64 / 30 MB cap, custom headers with reserved-header blocklist, tags).
2. Guardrails before accept: from-address must use a verified project domain; SES credentials present; quota synced within 6h (best-effort `GetAccount`); complaint-rate circuit breaker (blocks if ≥100 sends/30d and ≥0.1% complaints); all recipients checked against the suppression list (422 listing suppressed addresses).
3. Persist in a transaction: build full MIME (Symfony Mime), write `.eml` to storage, create Email (status `queued`) + recipients + attachment metadata, dispatch queued job after commit. API returns `202 {id}`.
4. Job (3 tries, backoff 5/30/120s): `queued → sending → sent`, calls SES v2 `/v2/email/outbound-emails` with raw base64 MIME — notably via hand-rolled SigV4 HTTP signing, no AWS SDK. Stores `ses_message_id`. Exhausted retries → `failed`.
5. Inbound events: `POST /api/webhooks/ses/{source.webhook_token}` (throttled 120/min) — verifies SNS signature (cert host pinned to `sns.{region}.amazonaws.com`), auto-confirms subscriptions, logs raw payload, matches email by `ses_message_id`, appends EmailEvent, advances status (`delivered/opened/clicked/bounced/complained/rejected/delayed`), creates suppressions (complaints + permanent bounces only; soft bounces don't suppress), broadcasts a real-time activity event, and fans out to customer webhooks.
6. Outbound webhooks: separate `webhooks` queue, HMAC-SHA256 `Larasend-Signature: t={ts},v1={sig}`, 3 tries with backoff, full delivery log.

**Client package**: `packages/larasend-laravel` — a Symfony mail transport so `MAIL_MAILER=larasend` works as a drop-in; maps the mail object to the HTTP API. (Rails equivalent: a small gem/`ActionMailer` delivery method.)

## Multi-Tenancy

Implicit and session-based — no subdomains, no tenant middleware, no global scopes:
- One workspace per user in practice (`ProjectContext` picks the user's lowest-id workspace and lazily auto-creates workspace/project/source on first use). No workspace switcher.
- "Current project" is a session value (`current_project_slug`); routes exist both bare (`/activity`) and project-prefixed (`/projects/{slug}/activity`).
- Isolation is enforced by always querying through relation chains (`workspace.projects...`) plus explicit `abort_unless(project_id matches, 404)` checks in controllers.
- On the API, **the API key is the tenant boundary** — it resolves project/workspace/source onto the request.

## Auth & Permissions

- Fortify: login, registration, email verification, password reset, full TOTP 2FA with recovery codes. Registration is open only while the instance has zero users (first user = owner) or via `LARASEND_OPEN_REGISTRATION`.
- No Policy/Gate classes. A role→capability map on Workspace with 6 roles: `owner` (everything), `member` (everything except manage members), `sender`, `api_keys`, `domains`, `read_only`. Every mutating dashboard action calls `authorizeWorkspaceCapability`.
- Roles are workspace-wide only — **no per-project permissions** despite the README claim.
- Member "invitations" = create user + send password-reset link + pivot row; no invitations table.

## Dashboard (Inertia/Vue)

Architecturally a **single page** (`Activity.vue`) driven by a `section` param through one invokable controller. Sections: activity / sent / bounces / complaints / suppressions / identities / templates / webhooks / api-keys / send / setup / projects.
- Activity: latest 50 emails, text search + time range (1h/24h/7d/30d), metric tiles with deltas + sparklines (sent, delivery/open/click/bounce rates, complaints), sidebar counts, CSV export.
- Inspector: full detail, event timeline, sandboxed-iframe HTML preview (strict CSP, no scripts), raw `.eml` download, **resend** (rebuilds payload, tags `resent_from`).
- Bounces: hard/soft queue with diagnostics, 30d bounce metrics, bulk "retry soft bounces" (up to 100).
- Identities/setup: add domain → creates SES identity → shows DKIM CNAMEs → "re-check DNS" button verifies; source credential management; manual quota sync; 5-step production checklist.
- API keys / webhooks / templates management with one-time secret reveal; webhook delivery log with success-rate stats.
- Onboarding wizard (workspace → source → domain → API key → test send) and a first-run gate.
- Real-time updates broadcast on every status change.

## Operations

Docker Compose: app (nginx+php-fpm), queue worker (`--queue=default,webhooks --tries=3`), Postgres 17, Redis. **No scheduled/cron tasks at all** — quota refresh is on-demand/lazy. Health check at `/up`. Good feature-level test coverage across API, webhook ingestion, dashboard actions, tenancy scoping, and roles.

## Weaknesses Worth Not Copying

- No idempotency keys on `POST /api/emails` — client retries duplicate sends.
- No rate limiting on the send endpoint (only the SNS webhook is throttled).
- Suppression check ignores `expires_at` (expired suppressions still block).
- No total-recipient cap across to+cc+bcc (SES raw send has a 50-recipient limit).
- Multi-workspace membership is half-built (no switcher); per-project permissions advertised but absent.
- No data-retention job despite a `retention_days` column on sources.
- Hand-rolled SigV4 instead of the AWS SDK (in Rails we'd use `aws-sdk-sesv2`).

## Rails Mapping (for when we implement)

The blank app is Rails 8.1 with SQLite + Solid Queue/Cache/Cable, Hotwire, Kamal — a near-perfect stack match:
- Inertia/Vue single-page dashboard → Hotwire (Turbo Frames/Streams) server-rendered sections; real-time activity via Turbo Streams over Solid Cable.
- Laravel queue jobs → Active Job on Solid Queue (default + webhooks queues); `afterCommit` → `enqueue_after_transaction_commit`.
- Fortify → Rails 8 built-in auth generator (add 2FA later if wanted).
- Encrypted AWS creds / signing secrets → Active Record encryption; API keys → `has_secure_token`-style + SHA-256 digest column.
- Symfony Mime → Ruby `Mail` gem for MIME building; store `.eml` via Active Storage or disk.
- SES calls → `aws-sdk-sesv2` gem; SNS verification → `aws-sdk` SNS message verifier.
- Laravel transport package → later, a tiny gem providing an ActionMailer delivery method.
- Postgres/Redis → SQLite + Solid Queue is fine to start; JSON columns work in SQLite via Rails `json` attributes.

## Confirmed Scope (user decisions)

- **Full feature set**: Tier 1 (core send loop) + Tier 2 (SNS feedback loop + activity dashboard) + Tier 3 (domains/DKIM, guardrails, outbound webhooks, templates, roles/members, onboarding, CSV export).
- **Include the improvements** larasend lacks: idempotency keys on `POST /api/emails`, per-key rate limiting on send, suppression `expires_at` honored, total-recipient cap of 50 (SES raw limit), retention job driven by `retention_days`.
- **Full multi-workspace tenancy** (better than larasend): users in multiple workspaces, workspace switcher, a real `invitations` table, larasend's 6-role capability map per workspace.

**Gems to add** (minimal): `aws-sdk-sesv2`, stdlib `csv` declaration. No Devise (Rails 8 auth generator), no rack-attack (Rails 8 `rate_limit`), `mail` already present via Action Mailer. SNS verification hand-ported if `Aws::SNS::MessageVerifier` is unavailable in current SDK majors.

## Implementation Phases (each independently shippable)

### Phase 0 — Foundation: auth, tenancy, membership
- `bin/rails generate authentication` (User/Session/Current). `RegistrationsController` open only when `User.none?` (first user = owner, auto-creates workspace) or `ENV["OPEN_REGISTRATION"]`. TOTP 2FA deferred to backlog.
- Migrations: `workspaces` (name, slug, owner_id, onboarded_at, setup_started_at), `memberships` (workspace_id, user_id, role, unique pair), `invitations` (email, role, token_digest, invited_by, accepted_at, expires_at), `projects` (workspace_id, name, slug unique-per-workspace, default_environment, archived_at).
- `Workspace::ROLE_CAPABILITIES` ported verbatim (owner/member/sender/api_keys/domains/read_only → send, manage_api_keys, manage_domains, manage_templates, manage_webhooks, manage_members). Controller concerns: `AuthorizesCapability` (`authorize_capability!`), `SetsCurrentWorkspace` (session workspace_id/project_slug, always scoped through `current_user.workspaces` / `Current.workspace.projects` — never unscoped finds).
- Tests: registration gating, invitation accept (new + existing user), workspace switching, cross-workspace 404s, 6×6 role capability matrix.

### Phase 1 — Core send domain + API accept path
- Migrations: `sources` (SES region/config set/default from, **Active Record-encrypted** aws_* columns — run `db:encryption:init`; `webhook_token` via `has_secure_token`; retention_days; `last_quota` json; unique `(project_id, environment)`), `api_keys` (prefix, key_hash sha256 unique, scopes json, expires_at, revoked_at, last_used telemetry), `emails` (public_id, status, ses_message_id, headers/tags json, mime_path/size; indexes `(project_id, status, created_at)`), `email_recipients`, `email_attachments` (metadata only), **`idempotency_keys`** (api_key_id + key unique, request fingerprint, email FK, 24h expiry). SQLite: `t.json` columns.
- `Email` status via enum + guarded `apply_event!` with precedence rules (no state-machine gem). `ApiKey.issue` → `dp_` + `SecureRandom.alphanumeric(48)`, SHA-256 digest, plaintext shown once.
- `Api::BaseController`: bearer auth, scope checks (`send` for POST, `read:activity` for GET), telemetry touch throttled to 1/min. Rails 8 `rate_limit to: 60, within: 1.minute, by: -> { @api_key.id }` after auth. `EmailSubmission` ActiveModel form object: full validation matrix incl. total-recipient ≤50, 25 attachments/30MB, reserved-header blocklist, subject XOR template. Idempotency: replay on match, 409 on fingerprint mismatch. `Suppression.active` scope (expiry-aware) wired from day one.

### Phase 2 — Send pipeline: MIME, storage, SES job
- `MimeBuilder` using the `mail` gem (multipart alternative, attachments, custom headers, `X-Departures-Id`). `.eml` to disk at `storage/emails/{project_id}/{public_id}.eml` behind a `MimeStore` wrapper (not Active Storage). Verify Bcc semantics against SESv2 raw send early (risk #2).
- `SendEmailJob` (queue `:default`, retry_on SES errors with 5/30/120 backoff, 3 attempts; terminal errors → `failed` with reason): guard `queued?`, `mark_sending!`, `Aws::SESV2::Client#send_email(content: {raw:})`, store `ses_message_id`, `mark_sent!`. Enqueue after commit. `config/queue.yml` declares `default,webhooks`.
- Test with `Aws::SESV2::Client.new(stub_responses: true)` injected via `Source#ses_client` (no webmock gem needed).

### Phase 3 — SNS ingestion, events, suppressions, live activity
- Migrations: `email_events` (event_type, ses_message_id, recipient, url/UA/IP, payload json, occurred_at), `webhook_logs` (raw inbound payloads + status), `suppressions` (unique `(project_id, email)`, reason, expires_at).
- `POST /api/webhooks/ses/:webhook_token` → thin controller (rate_limit 120/min): find source, log payload, **verify SNS signature** (port larasend's verifier: cert host pinned to `sns.{region}.amazonaws.com`, SignatureVersion 1/2 → SHA1/SHA256), auto-confirm subscriptions, enqueue `ProcessSesEventJob`.
- `ProcessSesEventJob`: normalize via a `SesEvent` value object (bounceType mapping), match by `ses_message_id`, create events, `apply_event!`, suppress on complaint + permanent bounce only, Turbo Stream broadcast to `[project, :activity]`, fan out to webhook endpoints (Phase 5).
- Tests from fixture SNS payloads copied from larasend's suite: every event type, bad signature, soft bounce no-suppress, expired suppression doesn't block sends.

### Phase 4 — Dashboard (Hotwire, conventional controllers per section — NOT larasend's single controller)
- `ActivityController` (latest 50, LIKE search, time range, status filter; Turbo Frame list + `turbo_stream_from` live rows via Solid Cable). `EmailsController#show` inspector drawer + member routes: `preview` (iframe-served HTML with strict CSP `default-src 'none'; img-src * data:`), `raw` (.eml `send_file`), `resend` (rebuild + tag `resent_from`, `send` capability).
- Metrics query object: tiles (sent, delivery/open/click/bounce rates, complaints) with prior-period deltas + `strftime`-bucketed sparklines, cached 60s in Solid Cache. `SuppressionsController` (list/add/remove), `BouncesController` (hard/soft queues, bulk retry-soft ≤100), `ExportsController` (CSV via stdlib), send-test form. Minimal Stimulus (clipboard, drawer, time-range).

### Phase 5 — Platform: domains/DKIM, guardrails, outbound webhooks, templates, onboarding
- `domains` migration + `DomainsController`: SESv2 `create_email_identity` → store DKIM CNAMEs → re-check via `get_email_identity` → verified. Flip on the from-domain-must-be-verified guardrail in `EmailSubmission`.
- Guardrails: `Source#sync_quota!` (SES `get_account`), stale-quota rejection (>6h), complaint-rate breaker (≥100 sends/30d and ≥0.1%).
- `webhook_endpoints` (encrypted `whsec_` secret, events json, active) + `webhook_deliveries`; `DeliverWebhookJob` (queue `:webhooks`, HMAC `Departures-Signature: t={ts},v1={sig}`, 3 tries, per-attempt delivery log). One-time secret reveal UI + delivery log with success rate.
- `templates` migration + controller; `{{ var }}` gsub renderer with HTML escaping (no Liquid). Onboarding wizard (workspace → source → domain → API key → test send) keyed off `setup_started_at`/`onboarded_at`.

### Phase 6 — Recurring work, retention, ops hardening
- `config/recurring.yml` (Solid Queue recurring — improvement over larasend's zero cron): `SyncQuotasJob` every 4h; `PruneRetentionJob` daily (emails + .eml files past `retention_days`, webhook logs/deliveries 30d, expired idempotency keys + invitations) using `in_batches` to keep SQLite locks short.
- Kamal: persistent volume for `storage/` (SQLite + .eml), `jobs` role running `bin/jobs`; health check `/up`. Full-loop smoke test: create key → POST (stubbed SES) → simulated SNS bounce → suppression + dashboard event.

## Top Risks

1. **SNS signature verification** — `Aws::SNS::MessageVerifier` may be absent in current SDK majors; hand-port larasend's verifier and test with captured payloads.
2. **Bcc semantics with SESv2 raw send** — recipients derive from MIME headers; verify bcc delivery/leak behavior against SES sandbox early in Phase 2.
3. **SQLite write contention** — SNS bursts + Solid Queue + telemetry writes; mitigated by separate solid_* DBs, thin webhook controller, throttled telemetry, batched deletes.
4. **Status transition races** — events arriving before `ses_message_id` commits or out of order; precedence-guarded `apply_event!` + unmatched-event policy, deliberately tested.
5. **Rails 8 `rate_limit` keyed by API key** — verify `by:` ordering relative to the auth before_action; fallback keys off the raw bearer header.

## Verification

- Per phase: `bin/rails test` green with the coverage listed in each phase (mirrors larasend's feature suite: API send/scopes/idempotency, SNS ingestion matrix, tenancy scoping, role matrix).
- End-to-end (Phase 6 smoke): run app, onboard, create key, `curl POST /api/emails` with stubbed SES, POST a fixture SNS bounce to the webhook, confirm status change, suppression row, live dashboard update, and blocked resend to the suppressed address.

# Departures — Master Execution Plan

> **For agentic workers:** This is the phase-by-phase execution map. Before implementing a phase, author its detailed TDD plan (see Section C). Phase 0's detailed plan already exists: `docs/plans/phase-0-foundation-plan.md`. Execute detailed plans with `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans`.

**Goal:** Build the Departures self-hosted SES email platform (scope: `docs/larasend-evaluation-and-plan.md`) in 7 independently shippable phases, with every task complying with `docs/patterns-and-best-practices.md` and `docs/style-guide.md`.

**Architecture:** Vanilla Rails 8.1 + SQLite + Solid Queue/Cache/Cable + Hotwire. Business logic in models composed from concerns; thin RESTful controllers; ultra-thin jobs via the `_now/_later` pattern; presenters as plain Ruby classes in `app/models/`; hand-written CSS on the style-guide token system.

**Tech Stack:** Rails 8.1, Ruby 3.4, SQLite, Solid Queue/Cache/Cable, Hotwire (Turbo + Stimulus), `aws-sdk-sesv2`, `mail` gem (via Action Mailer), Kamal.

## Global Constraints

- Default integer primary keys (user decision — NOT Talento HQ's UUIDs).
- No new gems beyond `aws-sdk-sesv2`, `bcrypt` (auth generator), and stdlib `csv` declaration. No Devise, no rack-attack, no state-machine gem, no CSS framework.
- API key prefix is `dp_`; webhook signature header is `Departures-Signature`; MIME id header is `X-Departures-Id`.
- Registration open only while `User.none?` or `ENV["OPEN_REGISTRATION"]` is set.
- All tests are Minitest + fixtures. `bin/rails test` and `bin/rubocop` must be green at the end of every task.
- Naming corrections vs. the roadmap doc (bang rule, patterns §5.1 — `!` only with a non-bang counterpart): use `apply_event`, `mark_sending`, `mark_sent`, `mark_failed`, `sync_quota` (no `!`).

---

## Section A — Pattern directives (every task in every phase inherits these)

### A1. Tenancy & Current context

- `Current` (from the Rails 8 auth generator, extended) carries `session`, `user` (delegated), `workspace`, `project`.
- Dashboard controllers ALWAYS scope through `Current.user.workspaces` / `Current.workspace.projects`. Never `Model.find(params[:id])` unscoped. Cross-tenant access must raise `ActiveRecord::RecordNotFound` (404), not 403.
- On the API, the API key is the tenant boundary: `Api::BaseController` authenticates the bearer token and sets `Current.workspace`, `Current.project`, and the request's source from the key. No session, no cookies.
- Background jobs capture `Current.workspace` automatically via the ActiveJob extension (Phase 0, Task 9 — patterns §4.5 adapted from account→workspace). Never pass workspace as a job argument.

### A2. Model layer

- **Lambda association defaults** (patterns §2.3), declaration order respected:

  ```ruby
  belongs_to :project
  belongs_to :workspace, default: -> { project.workspace }
  belongs_to :creator, class_name: "User", default: -> { Current.user }
  ```

- **Concerns** (patterns §2.1): model-specific concerns namespaced (`Email::Statuses`, `Email::Deliverable`, `Workspace::Roles`, `Project::Archivable`, `Source::Quota`). Shared adjective-named concerns (`Broadcastable`) only when 3+ unrelated models need the behavior. Don't extract concerns under ~50 lines of cohesive behavior.
- **Intention-revealing APIs** (§2.2): paired booleans (`archived?`/`active?`, `revoked?`/`active?`), imperative verbs (`archive`/`unarchive`, `revoke`, `suppress`, `resend`), delegation to hide implementation (`suppressed_at`, not `suppression&.created_at`). Multi-step state changes wrapped in `transaction do`.
- **Scopes tell stories** (§2.4): `scope :active`, `scope :pending`, `scope :reverse_chronologically`; UI param mapping via case-scopes `indexed_by(param)` / `sorted_by(param)` / `in_time_range(param)` so controllers stay conditional-free; `preloaded` scopes for N+1 prevention.
- **Callbacks minimal** (§2.5): `before_create` only for required data (`public_id`, token digests); `after_*_commit` only to enqueue `_later` work; never business logic in callbacks.
- **Presenters** (§3.4): plain Ruby classes in `app/models/` by domain — no `app/presenters/`. Constructor-injected dependencies, memoized collections, boolean display methods, `cache_key` for fragment caching. Factory methods on models for discoverability (`project.metrics_for(range)`).

### A3. Controllers

- **Thin controllers** (§4.1): set ivars via concern/before_action, call ONE model method, respond. Zero business logic, zero query building beyond named scopes.
- **RESTful resources, never custom actions** (§4.2). Verb → resource mappings for this project:

  | Action | Resource | Controller |
  |---|---|---|
  | resend an email | `resource :resend` | `Emails::ResendsController#create` |
  | bulk retry soft bounces | `resource :retry` | `Bounces::RetriesController#create` |
  | rotate an API key | `resource :rotation` | `ApiKeys::RotationsController#create` |
  | archive/unarchive project | `resource :archive` | `Projects::ArchivesController#create/destroy` |
  | re-check domain DNS | `resource :check` | `Domains::ChecksController#create` |
  | sync source quota | `resource :quota_sync` | `Sources::QuotaSyncsController#create` |
  | switch workspace | `resource :switch` | `Workspaces::SwitchesController#create` |
  | accept invitation | `resource :acceptance` | `Invitations::AcceptancesController#new/create` |

  Read-only representations (`preview`, `raw` on emails) may be member GETs.
- **Controller concerns** (§4.3): `SetsCurrentWorkspaceAndProject`, `AuthorizesCapability` (`authorize_capability! :manage_domains` → 403), `ProjectScoped`, `EmailScoped` — same shape as the patterns doc's `CardScoped`.

### A4. Jobs — `_now/_later` (§4.4)

Every job is 3–6 lines delegating to a synchronous model method. Canonical set:

| Job | Queue | Delegates to |
|---|---|---|
| `SendEmailJob` | `default` | `email.deliver` |
| `ProcessSesEventJob` | `default` | `webhook_log.process` |
| `DeliverWebhookJob` | `webhooks` | `webhook_delivery.deliver` |
| `SyncQuotasJob` | `default` | `Source.sync_all_quotas` |
| `PruneRetentionJob` | `default` | `Email.prune_expired` etc. (class methods) |

Models expose both versions: `deliver` / `deliver_later`, `process` / `process_later`. Logic is tested through the synchronous method; enqueueing through `assert_enqueued_with`.

### A5. Coding style (§5.1)

- Expanded conditionals over guard clauses (guards OK only at method start before a non-trivial body).
- Method order: class methods → public (`initialize` first) → private. Private methods in invocation order.
- Indent under `private`, no blank line after the modifier.
- Bang methods only when a non-bang counterpart exists.

### A6. Testing

- `Current.session = sessions(:name)` in every model-test setup that touches lambda defaults (gotcha §7.3.1).
- SES stubbed via `Aws::SESV2::Client.new(stub_responses: true)` injected through `Source#ses_client` — no webmock.
- SNS ingestion tested from fixture payload files (`test/fixtures/files/sns/*.json`).
- Each phase ends green: `bin/rails test`, `bin/rubocop`.

### A7. Frontend (style-guide.md)

- Pure custom CSS. `@layer reset, base, components, modules, utilities` architecture; OKLCH semantic tokens (`--color-ink`, `--color-surface`, `--color-border`, …); logical properties only (`inline-size`, `padding-block`); spacing via `--block-space`/`--inline-space`.
- Components: `.btn btn--primary|--secondary|--plain|--destroy btn--medium|--large`, `.input` (+ `--select`, `--textarea`, `--actor`), `.switch`, mask-based `icon_tag` icons (monochrome SVGs, `currentColor`).
- Dark mode via `html[data-theme="dark"]` + `prefers-color-scheme` fallback; respect `prefers-reduced-motion`; focus-visible rings on everything interactive.
- The app starts blank: Phase 0 Task 10 bootstraps `base.css`, `utilities.css`, `buttons.css`, `inputs.css` and the `icon_tag` helper. Every later view task: use existing tokens/utilities first; add component CSS in the right layer; verify light + dark.

---

## Section B — Phase task maps

Each phase below lists its tasks with files and pattern directives. The executing agent authors the phase's detailed TDD plan from this map + Section A before writing code.

### Phase 0 — Foundation: auth, tenancy, membership

Detailed plan: **`docs/plans/phase-0-foundation-plan.md`** (already written — 11 tasks: auth generator + Current extension, registration gating, Workspace/Membership/`Workspace::Roles`, first-user bootstrap, Projects + `Project::Archivable`, controller concerns, workspace switcher, invitations, ActiveJob workspace context, CSS foundation, wrap-up).

### Phase 1 — Core send domain + API accept path

Prereq: run `bin/rails db:encryption:init` and install the keys in credentials before the Source migration.

| Task | Files | Directives |
|---|---|---|
| 1.1 `Source` model | `app/models/source.rb`, migration | AR-encrypted `aws_access_key_id`/`aws_secret_access_key` (`encrypts`), `has_secure_token :webhook_token`, `retention_days`, `last_quota` (`t.json`), unique `(project_id, environment)`. Lambda default `workspace` from `project`. `ses_client` method (memoized, `stub_responses: true` injectable in test). |
| 1.2 `ApiKey` model | `app/models/api_key.rb`, migration | `ApiKey.issue(project:, scopes:, expires_in:)` class method → `"dp_" + SecureRandom.alphanumeric(48)`, stores sha256 `key_hash` + 12-char `prefix`, exposes plaintext once via `attr_reader :token`. `authenticate_by_token(bearer)` class method (sha256 lookup + active check). `revoke` / `revoked?` / `active?`; `rotate` (revoke + issue in transaction, `Api Keys::RotationsController` consumes later). `touch_usage(ip:, user_agent:)` throttled to 1/min internally. Scopes stored as `t.json`. |
| 1.3 `Email` + `Email::Statuses` | `app/models/email.rb`, `app/models/email/statuses.rb`, migrations (`emails`, `email_recipients`, `email_attachments`) | `public_id` via `before_create`; enum `status`; `Email::Statuses` concern holds `STATUS_PRECEDENCE` map and `apply_event(event_type)` — advances status only forward (guards races, risk #4). `mark_sending`/`mark_sent`/`mark_failed(reason)`. Index `(project_id, status, created_at)`. `headers`/`tags` as `t.json`. |
| 1.4 `IdempotencyKey` | `app/models/idempotency_key.rb`, migration | Unique `(api_key_id, key)`, request `fingerprint`, `email` FK, 24 h expiry. Class method `IdempotencyKey.replay_or_record(api_key:, key:, fingerprint:) { block }` → returns existing email on match, raises `MismatchError` on fingerprint conflict (controller maps to 409). |
| 1.5 `Suppression` (skeleton) | `app/models/suppression.rb`, migration | Unique `(project_id, email)`, `reason`, `expires_at`. `scope :active, -> { where(expires_at: nil).or(where(expires_at: Time.current..)) }` — expiry-aware from day one (named improvement). `Suppression.covers?(project, addresses)` returns suppressed subset. |
| 1.6 `EmailSubmission` form object | `app/models/email_submission.rb` | ActiveModel (plain class in models layer, presenter philosophy §3.4). Full validation matrix: from/to/cc/bcc ≤1000 each, **total recipients ≤50**, subject XOR template, html/text presence, ≤25 attachments / 30 MB, reserved-header blocklist, suppressed-recipient rejection (422 listing addresses). `save` builds Email + recipients + attachment metadata in one transaction and returns the email. Guardrail hooks (domain verified, quota fresh, complaint breaker) added in Phase 5 — leave seams as private predicate methods returning true for now. |
| 1.7 `Api::BaseController` + `Api::EmailsController` | `app/controllers/api/base_controller.rb`, `api/emails_controller.rb`, routes | Bearer auth → `ApiKey.authenticate_by_token`; sets `Current.workspace/project`; scope check per verb (`send` POST, `read:activity` GET); `rate_limit to: 60, within: 1.minute, by: -> { @api_key.id }` — **verify `rate_limit` runs after the auth before_action (risk #5); fallback: key off the raw bearer header**. `create` = instantiate `EmailSubmission`, `save`, respond `202 { id: }` — thin. |

Tests: issue/authenticate/revoke/rotate key; scope matrix; rate-limit 429; idempotent replay + 409 mismatch; full validation matrix; suppressed recipients 422; status precedence table.

### Phase 2 — Send pipeline: MIME, storage, SES job

Detailed plan: **docs/plans/phase-2-send-pipeline-plan.md** (complete).

| Task | Files | Directives |
|---|---|---|
| 2.1 `Email::MimeBuilder` | `app/models/email/mime_builder.rb` | Plain Ruby class (presenter shape): builds multipart/alternative via the `mail` gem, attachments, custom headers, `X-Departures-Id`. `to_eml` → String. |
| 2.2 `Email::MimeStore` | `app/models/email/mime_store.rb` | Disk wrapper (not Active Storage): `write(email, eml)` → `storage/emails/{project_id}/{public_id}.eml`, `read(email)`, `delete(email)`; path/size stored on Email. |
| 2.3 `Email::Deliverable` | `app/models/email/deliverable.rb`, `app/jobs/send_email_job.rb`, `config/queue.yml` | `deliver`: guard `queued?` (guard OK — start of non-trivial body), `mark_sending`, `source.ses_client.send_email(content: { raw: })`, store `ses_message_id`, `mark_sent`. `deliver_later` enqueues `SendEmailJob` (3 lines, `retry_on Aws::SESV2::Errors::ServiceError, wait: :polynomially_longer, attempts: 3`; discard → `mark_failed(reason)`). Enqueued from `EmailSubmission#save` after commit (extension from Phase 0 Task 9 guarantees it). `queue.yml` declares `default,webhooks`. |
| 2.4 Bcc spike | `docs/notes/bcc-ses-findings.md` | **Early risk #2 check**: verify Bcc semantics of SESv2 raw send against the SES sandbox (recipients derive from MIME headers — confirm bcc delivery without header leak). Document findings; adjust MimeBuilder before proceeding. |

Tests: MIME structure assertions (parts, headers, attachment encoding); store round-trip; `deliver` happy path + SES error → retry → failed, all with stubbed SES client; `assert_enqueued_with(job: SendEmailJob)`.

### Phase 3 — SNS ingestion, events, suppressions, live activity

| Task | Files | Directives |
|---|---|---|
| 3.1 Migrations + models | `email_events`, `webhook_logs` migrations; `app/models/email_event.rb`, `webhook_log.rb` | EmailEvent: `event_type`, `ses_message_id`, `recipient`, `url`/`user_agent`/`ip`, `payload` json, `occurred_at`. WebhookLog: raw inbound payload + processing status. |
| 3.2 `Sns::MessageVerifier` | `lib/sns/message_verifier.rb` | **Risk #1**: hand-port larasend's verifier — cert host pinned to `sns.{region}.amazonaws.com`, SignatureVersion 1/2 → SHA1/SHA256. Pure Ruby, unit-tested with captured payloads + tampered variants. |
| 3.3 `Email::SesEvent` value object | `app/models/email/ses_event.rb` | Normalizes SNS payloads: `event_type`, `bounce_type` mapping (permanent/transient), `recipients`, `occurred_at`, open/click metadata. Plain class, exhaustively unit-tested. |
| 3.4 Inbound controller | `app/controllers/webhooks/ses_controller.rb`, route `POST /api/webhooks/ses/:webhook_token` | Thin + `rate_limit to: 120, within: 1.minute`: find source by token (404 unknown), create WebhookLog, verify signature, auto-confirm `SubscriptionConfirmation`, `webhook_log.process_later`. No business logic. |
| 3.5 `WebhookLog#process` | `app/models/webhook_log.rb`, `app/jobs/process_ses_event_job.rb` | All ingestion logic here (thin job): parse via `Email::SesEvent`, match email by `ses_message_id` (unmatched-event policy: mark log unmatched, keep payload), create EmailEvents, `email.apply_event`, suppress on complaint + permanent bounce ONLY (soft bounces never suppress), broadcast, fan out to webhook endpoints (no-op seam until Phase 5). |
| 3.6 `Broadcastable` | `app/models/concerns/broadcastable.rb` | Turbo Stream broadcast to `[project, :activity]` on status change — shared concern, model-driven (not controller). |

Tests from fixture SNS payloads (every event type): bad signature 403, soft bounce no-suppress, expired suppression doesn't block sends, out-of-order events don't regress status (risk #4), unmatched event policy.

### Phase 4 — Dashboard (Hotwire; conventional controllers per section)

| Task | Files | Directives |
|---|---|---|
| 4.1 Email filter scopes | `app/models/email.rb` | `indexed_by(param)` (sent/bounces/complaints…), `sorted_by`, `in_time_range("1h"/"24h"/"7d"/"30d")`, `search(q)` LIKE scope, `preloaded`. Keeps ALL filtering out of controllers (§2.4). |
| 4.2 `ActivityController` | controller + views + Stimulus | Latest 50 via scopes; Turbo Frame list + `turbo_stream_from [Current.project, :activity]` for live rows (Solid Cable). Style-guide components throughout. |
| 4.3 `Project::Metrics` presenter | `app/models/project/metrics.rb` | Tiles (sent, delivery/open/click/bounce rates, complaints), prior-period deltas, `strftime`-bucketed sparklines. Memoized, `cache_key`, cached 60 s in Solid Cache. Factory `project.metrics_for(range)`. Read the `dataviz` skill before building sparkline markup. |
| 4.4 `EmailsController` + inspector | `emails_controller.rb`, `emails/resends_controller.rb` | `show` drawer (Turbo Frame); member GET `preview` (iframe HTML, CSP `default-src 'none'; img-src * data:`), `raw` (`send_file` .eml). Resend = `Emails::ResendsController#create` → `email.resend` model method (rebuilds submission, tags `resent_from`), guarded by `authorize_capability! :send`. |
| 4.5 Suppressions/Bounces/Exports | `suppressions_controller.rb`, `bounces_controller.rb`, `bounces/retries_controller.rb`, `exports_controller.rb` | Suppressions list/create/destroy; bounce queues via scopes (`hard_bounced`, `soft_bounced`); bulk retry = `Bounces::RetriesController#create` → `Email.retry_soft_bounces(limit: 100)` class method; CSV via stdlib `csv` (add `gem "csv"`). |
| 4.6 Send-test form + Stimulus utilities | views, `app/javascript/controllers/` | Minimal Stimulus: clipboard, drawer, time-range picker. All styling from Phase 0 foundation + component CSS in `modules` layer. |

### Phase 5 — Platform: domains, guardrails, outbound webhooks, templates, onboarding

| Task | Files | Directives |
|---|---|---|
| 5.1 `Domain` + controllers | model, migration, `domains_controller.rb`, `domains/checks_controller.rb` | `create` → `domain.provision` (SESv2 `create_email_identity`, store DKIM CNAMEs, status `pending`); re-check = `Domains::ChecksController#create` → `domain.check` (`get_email_identity` → `verified`). `verified?`/`pending?` booleans; capability `manage_domains`. |
| 5.2 Guardrails | `app/models/source/quota.rb`, `EmailSubmission` | `Source::Quota` concern: `sync_quota` (SES `get_account`), `quota_stale?` (>6 h), `complaint_rate_exceeded?` (≥100 sends/30 d AND ≥0.1 %). Wire the Phase 1 seams in `EmailSubmission`; flip on from-domain-must-be-verified. |
| 5.3 Outbound webhooks | `webhook_endpoint.rb`, `webhook_delivery.rb`, migrations, `DeliverWebhookJob`, controllers | Endpoint: encrypted `whsec_` secret (`encrypts`), `events` json, `active`. `WebhookDelivery#deliver` holds HTTP + HMAC `Departures-Signature: t={ts},v1={sig}` + per-attempt log (status, latency, body); thin job on `:webhooks`, 3 tries. Fan-out from `WebhookLog#process` (fills the Phase 3 seam). One-time secret reveal UI; delivery log with success rate. |
| 5.4 `Template` | model, migration, controller | `render(vars)` → `{{ var }}` gsub with HTML escaping (no Liquid). Slug unique per project. Capability `manage_templates`. `EmailSubmission` resolves `template_id` → subject/bodies. |
| 5.5 Onboarding wizard | `onboarding_controller.rb` or steps as nested resources, views | Workspace → source → domain → API key → test send; keyed off `setup_started_at`/`onboarded_at`; first-run gate in `SetsCurrentWorkspaceAndProject`. |

### Phase 6 — Recurring work, retention, ops

| Task | Files | Directives |
|---|---|---|
| 6.1 Recurring jobs | `config/recurring.yml`, `SyncQuotasJob`, `PruneRetentionJob` | `SyncQuotasJob` every 4 h → `Source.sync_all_quotas`; `PruneRetentionJob` daily → class methods `Email.prune_expired` (respects `source.retention_days`, deletes `.eml` via MimeStore), `WebhookLog.prune`, `WebhookDelivery.prune` (30 d), `IdempotencyKey.prune_expired`, `Invitation.prune_expired`. All use `in_batches` (SQLite lock hygiene, risk #3). Logic in models; jobs stay 3-liners. |
| 6.2 Kamal + smoke test | `config/deploy.yml`, `test/integration/full_loop_test.rb` | Persistent volume for `storage/`; `jobs` role running `bin/jobs`; health `/up`. Smoke: onboard → create key → POST /api/emails (stubbed SES) → fixture SNS bounce → assert status change, suppression row, live dashboard broadcast, blocked resend to suppressed address. |

---

## Section C — Execution protocol

1. **Per phase**: author `docs/plans/phase-N-<name>-plan.md` in `superpowers:writing-plans` format (checkbox steps, complete code, exact commands) from this map + Section A + the two standards docs. Self-review for roadmap coverage before executing.
2. **Execute** task-by-task via `superpowers:subagent-driven-development`; each task ends with `bin/rails test` + `bin/rubocop` green and a commit.
3. **Task preludes** in detailed plans must name the standards sections to re-read: model tasks → patterns Part 2 + §5.1; controller tasks → Part 4.1–4.3; job tasks → §4.4–4.5; view tasks → style-guide (tokens, buttons, inputs, icons, dark mode).
4. **Phase close**: `superpowers:requesting-code-review` against both standards docs + the roadmap's per-phase test list; then update this document's phase status.

## Verification (project-level)

- Per phase: the roadmap's "Tests" bullets for that phase all exist and pass.
- End-to-end: the Phase 6 smoke test mirrors the roadmap's Verification section (send → SNS bounce → suppression → dashboard → blocked resend).
- Standards: no custom routes where a resource fits; no business logic in controllers/jobs; `rg "def \w+!"` finds only bang methods with non-bang counterparts; CSS additions use tokens (no raw color values in feature CSS).

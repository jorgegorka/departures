# Phase 8 — Security Hardening: Design Spec

**Date:** 2026-07-11
**Status:** Approved for planning
**Scope:** TOTP 2FA with recovery codes, workspace 2FA enforcement, session management, workspace audit log, closing adversarial security review.

Phases 0–7 of `docs/plans/departures-execution-plan.md` are complete. This phase delivers the one item the original evaluation explicitly deferred (TOTP 2FA) plus the security surface around it. All Section A pattern directives of the execution plan apply: concern-heavy models, thin RESTful controllers, `_now/_later` jobs, Minitest + fixtures, no new gems, hand-written CSS.

## Decisions made during brainstorming

- **2FA policy:** optional per-user enrollment, plus per-workspace enforcement (owners can require 2FA; unenrolled members are blocked from that workspace only).
- **Audit log shape:** workspace-scoped `audit_events` table with explicit, curated `AuditEvent.record` calls at sensitive spots — no model-callback magic, no log-file-only approach.
- **QR delivery:** vendored dependency-free `qrcodegen.js` (~5 KB) pinned under `vendor/javascript` via importmap, rendered client-side by a Stimulus controller. No gem, no external call; the otpauth URI never leaves the page. Manual-entry secret shown alongside.
- **Structure:** features first (2FA → enforcement → sessions → audit log), adversarial security review as the closing task so it covers the new attack surface too.

## Task 8.1 — TOTP core (model layer)

**`lib/totp.rb`** — pure-Ruby RFC 6238 implementation (no gem):

- `Totp.new(secret)` with `provisioning_uri(account:, issuer: "Departures")`, `verify(code, at: Time.current, drift: 1)` returning the matched timestep (or nil), and `Totp.generate_secret` (Base32, 160-bit).
- HMAC-SHA1, 30-second step, 6 digits, ±1 step drift window.
- Unit-tested against the RFC 6238 Appendix B test vectors (adapted to SHA-1/6-digit) plus drift and tamper cases.

**`users` migration** adds:

- `otp_secret` — string, AR-encrypted via `encrypts` (same pattern as `Source` AWS keys).
- `otp_enabled_at` — datetime; null means disabled.
- `otp_consumed_timestep` — integer; the last accepted TOTP timestep, blocking replay of a just-used code.
- `otp_recovery_codes` — json array of SHA-256 digests.

**`User::TwoFactor` concern** (`app/models/user/two_factor.rb`):

- Paired booleans `two_factor_enabled?` / `two_factor_disabled?` (from `otp_enabled_at`).
- `prepare_two_factor` — generates and stores a fresh secret while still disabled (enrollment start).
- `enable_two_factor(code)` — verifies one valid TOTP against the pending secret before setting `otp_enabled_at`; generates 10 recovery codes, stores digests, returns plaintext codes once. Wrapped in a transaction.
- `disable_two_factor` — clears secret, timestamp, timestep, recovery codes.
- `verify_totp(code)` — delegates to `Totp#verify`, rejects timesteps ≤ `otp_consumed_timestep`, records the consumed timestep on success (transaction).
- `redeem_recovery_code(code)` — constant-time digest comparison, single-use (digest removed in the same transaction), returns boolean.

## Task 8.2 — Enrollment UI + login challenge

**Enrollment** — `Users::TwoFactorsController` (`resource :two_factor` under a user-settings namespace):

- `new` — calls `prepare_two_factor`, shows QR (client-side render of the provisioning URI) + copyable Base32 secret for manual entry.
- `create` — requires current password re-entry + a valid TOTP; on success shows the 10 recovery codes exactly once (print/copy affordances).
- `destroy` — requires current password re-entry; disables 2FA.
- Recovery-code regeneration: `Users::RecoveryCodesController#create` (`resource :recovery_codes`), password-gated, invalidates old codes.

**QR rendering** — vendor `qrcodegen.js` (Project Nayuki, MIT, dependency-free) under `vendor/javascript`, pin via importmap; a small Stimulus `qr-code` controller reads the URI from a `data` attribute and draws to a canvas/SVG. `bin/importmap audit` stays green.

**Login challenge** — `SessionsController#create` verifies the password; if the user has 2FA enabled it does **not** create a `Session`. Instead it stores the pending user id in a short-lived signed value (10-minute expiry) and redirects to the challenge:

- `Sessions::ChallengesController` (`resource :challenge`): `new` renders the code form (TOTP or recovery code, one field); `create` verifies via `verify_totp` falling back to `redeem_recovery_code`, then creates the session through the existing `start_new_session_for` path and clears the pending value.
- Expired/absent pending value → redirect to login.
- `rate_limit to: 10, within: 3.minutes` on `create`, mirroring `SessionsController`.
- Audit events on challenge success via recovery code (signals code consumption).

## Task 8.3 — Workspace 2FA enforcement

- `workspaces` migration: `require_two_factor` boolean, default false, null false.
- Toggle lives in workspace settings behind the existing `manage_members` capability.
- Gate in `SetsCurrentWorkspaceAndProject`: when `Current.workspace.require_two_factor?` and `Current.user.two_factor_disabled?`, redirect to 2FA enrollment with an explanatory notice. Blocks that workspace only — other workspaces (and the workspace switcher) remain reachable.
- The enrollment/challenge/session-management routes themselves are exempt from the gate (no redirect loop).
- API requests are unaffected (API keys are the API tenant boundary).

## Task 8.4 — Session management

- `sessions` migration: add `last_active_at` datetime. Touched from the authentication concern at most once per minute (same throttle shape as `ApiKey#touch_usage`).
- `SessionsController#index` — lists `Current.user.sessions` (reverse-chronological by activity): browser/OS summary parsed from user agent (small presenter, no gem), IP, created, last active. The current session is badged and has no revoke button.
- `SessionsController#destroy` already exists for logout; extend to accept an id scoped through `Current.user.sessions` (unknown/foreign id → 404), so any listed session can be revoked. Revoking the current session logs out.
- "Log out other sessions": `resource :other_sessions, only: :destroy` → `OtherSessionsController#destroy` deletes all of `Current.user.sessions` except the current one.
- Session revocations write audit events.

## Task 8.5 — Audit log

**`audit_events` table:** `workspace` FK, `user` FK (actor, nullable for system actions), `action` string (dot-namespaced, e.g. `api_key.revoked`), polymorphic `subject` (nullable — subject may be deleted later; keep type/id), `metadata` json, `ip` string, `created_at`. Index `(workspace_id, created_at)` and `(workspace_id, action)`.

**`AuditEvent.record(action, subject: nil, metadata: {})`** — pulls actor and workspace from `Current`, IP from a new `Current.ip` (set by a before_action in `ApplicationController`). Recording never raises into the caller's flow beyond validation of programmer error (unknown action names fail loudly in test via an allowlist constant).

**Curated call sites** (each inside the model method that performs the change, not the controller):

- API keys: issued, revoked, rotated.
- Memberships: created, role changed, removed. Invitations: created, accepted, revoked.
- Domains: created, verified, destroyed.
- Sources: created, credentials updated, destroyed.
- Webhook endpoints: created, updated, destroyed.
- Suppressions: created (manual), destroyed.
- 2FA: enabled, disabled, recovery codes regenerated, recovery code redeemed. (User-level events attach to the workspace(s) via `Current.workspace` when present; login-time events with no workspace record `workspace: nil` — see viewer note.)
- Workspace: `require_two_factor` toggled.
- Sessions: revoked (single and bulk).

User-level events without a workspace context (e.g. challenge-time recovery redemption) are stored with a null workspace and surface only in that user's own view — the workspace viewer shows workspace-scoped rows only.

**Viewer** — `AuditEventsController#index`, scoped `Current.workspace.audit_events`, filter scopes `indexed_by(action_group)` / `in_time_range(param)` per patterns §2.4, behind a new `view_audit_log` capability added to `Workspace::Roles`, granted to exactly the roles that already hold `manage_members`.

**Retention** — `AuditEvent.prune` (180 days, `in_batches`) added to the existing `PruneRetentionJob`.

## Task 8.6 — Closing adversarial security review

Run `superpowers:requesting-code-review` (or an equivalent multi-agent adversarial pass) across the whole app with dimensions: authentication and the new 2FA/challenge flow, tenancy isolation (cross-workspace 404s), API auth and scope enforcement, SNS signature verification, webhook endpoint SSRF, secrets and encrypted-column handling, rate limits, security headers/CSP, and brakeman findings. Confirmed findings are fixed within the phase; each fix gets a regression test.

## Testing summary

- `Totp` unit tests: RFC 6238 vectors, drift window, invalid/short codes.
- Replay rejection: a code accepted once is rejected inside the same timestep.
- Enrollment flow: prepare → wrong code rejected → correct code enables → recovery codes shown once; password re-entry required for enable/disable.
- Challenge integration: password-only login for 2FA users creates no session; TOTP path, recovery path (code consumed), expired pending value, rate limit 429-equivalent redirect.
- Enforcement: enforced workspace blocks unenrolled member, other workspaces reachable, no redirect loop on the enrollment screens.
- Sessions: list scoped to current user, foreign session id 404s, other-sessions bulk revoke keeps current session, `last_active_at` throttle.
- Audit: one test per curated call site asserting the event row (action, actor, subject, workspace); viewer capability matrix; prune respects 180 days.
- Phase-end: `bin/rails test`, `bin/rubocop`, brakeman, `bin/importmap audit` all green.

## Out of scope

- Password-change flow changes (and session revocation on password change).
- WebAuthn/passkeys.
- 2FA on the API surface (API keys remain the boundary).
- Audit-log export/webhooks.

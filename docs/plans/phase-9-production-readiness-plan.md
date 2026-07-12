# Phase 9 — Production Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Departures to production on Jorge's VPS with Kamal + Let's Encrypt, enable force_ssl/CSP, add nightly backups and SES-based error alerting, and clear the Phase 8 post-merge follow-ups.

**Architecture:** Ops work is host-level (Kamal config, cron backup script); the only new app code is `Ops::ErrorNotifier` (a plain Ruby class subscribed via `Rails.error.subscribe`), the CSP initializer, and small Phase 8 follow-up fixes. Spec: `docs/superpowers/specs/2026-07-12-phase-9-production-readiness-design.md`.

**Tech Stack:** Rails 8.1, Kamal 2 (kamal-proxy + Let's Encrypt), ghcr.io registry, sqlite3 CLI + rclone (host), `aws-sdk-sesv2`, `mail` gem.

## Global Constraints

- No new gems. Minitest + fixtures only.
- `bin/rails test` and `bin/rubocop` green at the end of every task; commit per task.
- Bang methods only with a non-bang counterpart. Expanded conditionals over guard clauses (guards OK only at method start). Method order: class methods → public → private; indent under `private`.
- Plain Ruby classes live in `app/models/` by domain (no `app/services/`).
- Tests that touch lambda association defaults set `Current.session = sessions(:name)` in setup.
- SES always stubbed in tests (`stub_responses: Rails.env.test?` pattern from `Source#ses_client`).

## Execution inputs (get from Jorge before Tasks 6–10)

| Placeholder | Meaning |
|---|---|
| `<VPS_IP>` | Public IPv4 of the existing VPS |
| `<APP_DOMAIN>` | Domain the app serves (DNS A record → `<VPS_IP>`) |
| ghcr PAT | GitHub personal access token with `write:packages`, stored in the `KAMAL_REGISTRY_PASSWORD` env var on Jorge's machine |
| ops SES credentials | IAM key pair allowed `ses:SendRawEmail`/`SendEmail`, region, alert from/to addresses — entered into Rails credentials in Task 9 |

Tasks 1–5 need none of these and can start immediately.

---

### Task 1: Already-enrolled guard on 2FA enrollment (Phase 8 follow-up)

**Files:**
- Modify: `app/controllers/users/two_factors_controller.rb`
- Test: `test/controllers/users/two_factors_controller_test.rb`

**Interfaces:**
- Consumes: `Current.user.two_factor_enabled?` (existing, `User::TwoFactor`), `user_sessions_path` (existing Security page route), `enable_two_factor_for(user)` test helper (existing, `test/test_helper.rb`).
- Produces: nothing used by later tasks.

Today a user who already has 2FA enabled can hit `GET /two_factor/new`, which calls `prepare_two_factor` and rotates their secret, silently breaking their authenticator. Guard `new`/`create` (NOT `destroy` — disabling requires being enrolled).

- [ ] **Step 1: Write the failing tests**

Append inside the class in `test/controllers/users/two_factors_controller_test.rb` (existing setup signs in `users(:owner)` as `@user`; the owner's password fixture is `secret123456`):

```ruby
test "new redirects when already enrolled without rotating the secret" do
  enable_two_factor_for @user
  secret_before = @user.reload.otp_secret

  get new_two_factor_path

  assert_redirected_to user_sessions_path
  assert_equal secret_before, @user.reload.otp_secret
end

test "create redirects when already enrolled" do
  enable_two_factor_for @user

  post two_factor_path, params: { password: "secret123456", code: "000000" }

  assert_redirected_to user_sessions_path
  assert @user.reload.two_factor_enabled?
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/users/two_factors_controller_test.rb`
Expected: the two new tests FAIL (`new` responds 200 and rotates the secret; `create` re-renders instead of redirecting).

- [ ] **Step 3: Add the guard**

In `app/controllers/users/two_factors_controller.rb`, add the `before_action` after the existing `allow_*` macros and the private method at the bottom:

```ruby
class Users::TwoFactorsController < ApplicationController
  allow_unonboarded_access
  allow_two_factor_unenrolled_access

  before_action :redirect_enrolled, only: %i[ new create ]

  def new
    unless Current.user.two_factor_enabled?
      Current.user.prepare_two_factor
    end
    @totp = Totp.new(Current.user.otp_secret)
  end

  # ... create and destroy unchanged ...

  private
    def redirect_enrolled
      if Current.user.two_factor_enabled?
        redirect_to user_sessions_path, notice: "Two-factor authentication is already enabled."
      end
    end
end
```

With the guard in place, `new` only ever runs for unenrolled users, so drop its now-redundant `unless`:

```ruby
  def new
    Current.user.prepare_two_factor
    @totp = Totp.new(Current.user.otp_secret)
  end
```

- [ ] **Step 4: Run the file, then the full suite + rubocop**

Run: `bin/rails test test/controllers/users/two_factors_controller_test.rb` → all PASS
Run: `bin/rails test && bin/rubocop` → green

- [ ] **Step 5: Commit**

```bash
git add app/controllers/users/two_factors_controller.rb test/controllers/users/two_factors_controller_test.rb
git commit -m "fix: block re-enrollment in 2FA so an enrolled user's secret is never rotated"
```

---

### Task 2: Drop unused `:subject` from `AuditEvent.preloaded` (Phase 8 follow-up)

**Files:**
- Modify: `app/models/audit_event.rb:22`
- Test: existing suites only (behavior-preserving removal)

**Interfaces:**
- Consumes: nothing new.
- Produces: `AuditEvent.preloaded` now `includes(:user)` only.

The audit viewer renders action/metadata/user/ip and never touches the polymorphic `subject` association (verify: `grep -rn "subject" app/views/audit_events/` returns nothing), so preloading it is wasted queries.

- [ ] **Step 1: Confirm the association is unused in views and controllers**

Run: `grep -rn "subject" app/views/audit_events/ app/controllers/audit_events_controller.rb`
Expected: no output. (If any usage appears, STOP and report — the follow-up note would be wrong.)

- [ ] **Step 2: Make the change**

In `app/models/audit_event.rb` change:

```ruby
scope :preloaded, -> { includes(:user, :subject) }
```

to:

```ruby
scope :preloaded, -> { includes(:user) }
```

- [ ] **Step 3: Run tests + rubocop**

Run: `bin/rails test test/models/audit_event_test.rb test/controllers/audit_events_controller_test.rb && bin/rubocop`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add app/models/audit_event.rb
git commit -m "chore: stop preloading unused polymorphic subject on audit events"
```

---

### Task 3: Audit-row assertions for the 5 uncovered actions (Phase 8 follow-up)

**Files:**
- Test: `test/controllers/audit_instrumentation_controller_test.rb`

**Interfaces:**
- Consumes: existing instrumentation in `DomainsController#create/#destroy`, `SourcesController#create`, `WebhookEndpointsController#create/#update`; fixtures `domains(:acme_com)`, `webhook_endpoints(:acme_all)`; `sign_in_as users(:owner)` (existing setup).
- Produces: nothing used by later tasks.

Instrumentation exists for all 23 allowlisted actions, but 5 have no test asserting the row: `domain.created`, `domain.destroyed`, `source.created`, `webhook_endpoint.created`, `webhook_endpoint.updated`. SES calls made by domain create/destroy go through `Source#ses_client`, which is auto-stubbed in test env.

- [ ] **Step 1: Add the tests**

Append inside `AuditInstrumentationControllerTest`:

```ruby
test "domain create and destroy are audited" do
  post domains_path, params: { domain: { name: "audit-example.com" } }
  assert AuditEvent.exists?(action: "domain.created"), "expected a domain.created audit event"

  delete domain_path(domains(:acme_com))
  assert AuditEvent.exists?(action: "domain.destroyed"), "expected a domain.destroyed audit event"
end

test "creating a source is audited" do
  post sources_path, params: { source: { name: "Audit source", environment: "staging",
    region: "eu-west-1", aws_access_key_id: "AKIAAUDIT", aws_secret_access_key: "audit-secret" } }

  source = Source.find_by!(name: "Audit source")
  assert AuditEvent.exists?(action: "source.created", subject: source)
end

test "webhook endpoint create and update are audited" do
  post webhook_endpoints_path, params: { webhook_endpoint: { url: "https://hooks.example.com/audit",
    events: [ "bounce" ], active: true } }
  endpoint = WebhookEndpoint.find_by!(url: "https://hooks.example.com/audit")
  assert AuditEvent.exists?(action: "webhook_endpoint.created", subject: endpoint)

  patch webhook_endpoint_path(webhook_endpoints(:acme_all)),
    params: { webhook_endpoint: { url: "https://hooks.acme.com/renamed" } }
  assert AuditEvent.exists?(action: "webhook_endpoint.updated", subject: webhook_endpoints(:acme_all))
end
```

- [ ] **Step 2: Run the file**

Run: `bin/rails test test/controllers/audit_instrumentation_controller_test.rb`
Expected: PASS. If the domain or source create redirects with a validation alert instead of creating (e.g. an unforeseen required param), inspect `Domain`/`Source` validations and adjust the params — do not weaken the assertions.

- [ ] **Step 3: Full suite + rubocop, then commit**

Run: `bin/rails test && bin/rubocop` → green

```bash
git add test/controllers/audit_instrumentation_controller_test.rb
git commit -m "test: audit-row assertions for domain, source and webhook endpoint actions"
```

---

### Task 4: Audit-event prune wiring test (Phase 8 follow-up)

**Files:**
- Test: `test/jobs/prune_retention_job_test.rb`

**Interfaces:**
- Consumes: `AuditEvent.prune` (existing, deletes rows older than 180 days), already called by `PruneRetentionJob#perform`.
- Produces: nothing used by later tasks.

`PruneRetentionJob` already calls `AuditEvent.prune`, but the job test doesn't cover it — a refactor could drop the line silently.

- [ ] **Step 1: Extend the existing test**

In the `"perform prunes every retention-bound table in one pass"` test, add before `PruneRetentionJob.perform_now`:

```ruby
old_audit = AuditEvent.create!(action: "domain.created", created_at: 181.days.ago)
fresh_audit = AuditEvent.create!(action: "domain.created")
```

and after the existing assertions:

```ruby
assert_not AuditEvent.exists?(old_audit.id)
assert AuditEvent.exists?(fresh_audit.id)
```

- [ ] **Step 2: Run, verify it passes (wiring already exists — this is a pin, not TDD red/green)**

Run: `bin/rails test test/jobs/prune_retention_job_test.rb`
Expected: PASS.

Sanity-check the pin bites: temporarily comment out `AuditEvent.prune` in `app/jobs/prune_retention_job.rb`, re-run (expected: FAIL), restore the line, re-run (expected: PASS).

- [ ] **Step 3: Commit**

```bash
git add test/jobs/prune_retention_job_test.rb
git commit -m "test: pin audit-event pruning into the retention job"
```

---

### Task 5: `Ops::ErrorNotifier` — error alerts via dedicated SES credentials

**Files:**
- Create: `app/models/ops/error_notifier.rb`
- Create: `config/initializers/error_reporting.rb`
- Test: `test/models/ops/error_notifier_test.rb`

**Interfaces:**
- Consumes: `Rails.error.subscribe` (Rails error-reporting API — subscribers implement `report(error, handled:, severity:, context:, source:)`); `Rails.cache` (Solid Cache in production, memory store in test); `Mail` gem; `Aws::SESV2::Client`.
- Produces: `Ops::ErrorNotifier.new(settings: <hash-like>)` with `#report(error, handled:, severity:, context: {}, source: nil)` and `attr_writer :ses_client` for test injection. Settings default to `Rails.application.credentials.ops` (keys: `aws_access_key_id`, `aws_secret_access_key`, `region`, `from`, `to`) — entered into credentials in Task 9.

Behavior: only unhandled errors alert; no-op when credentials are absent (dev/test); at most one email per error class per 10 minutes (Solid Cache `unless_exist` write); the notifier itself must never raise.

- [ ] **Step 1: Write the failing tests**

Create `test/models/ops/error_notifier_test.rb`:

```ruby
require "test_helper"

class Ops::ErrorNotifierTest < ActiveSupport::TestCase
  SETTINGS = { aws_access_key_id: "AKIAOPS", aws_secret_access_key: "ops-secret",
               region: "eu-west-1", from: "alerts@departures.example", to: "jorge@example.com" }.freeze

  setup do
    @notifier = Ops::ErrorNotifier.new(settings: SETTINGS)
    @client = Aws::SESV2::Client.new(stub_responses: true)
    @notifier.ses_client = @client
    @error = ArgumentError.new("boom")
  end

  test "emails an unhandled error through SES" do
    @notifier.report(@error, handled: false, severity: :error, context: { job: "SendEmailJob" }, source: "application.active_job")

    assert_equal 1, @client.api_requests.size
    raw = @client.api_requests.first[:params][:content][:raw][:data]
    assert_includes raw, "ArgumentError"
    assert_includes raw, "boom"
    assert_includes raw, "To: jorge@example.com"
  end

  test "ignores handled errors" do
    @notifier.report(@error, handled: true, severity: :warning, context: {})

    assert_empty @client.api_requests
  end

  test "throttles repeats of the same error class within the window" do
    @notifier.report(@error, handled: false, severity: :error, context: {})
    @notifier.report(ArgumentError.new("boom again"), handled: false, severity: :error, context: {})

    assert_equal 1, @client.api_requests.size
  end

  test "a different error class alerts despite the throttle" do
    @notifier.report(@error, handled: false, severity: :error, context: {})
    @notifier.report(TypeError.new("other"), handled: false, severity: :error, context: {})

    assert_equal 2, @client.api_requests.size
  end

  test "no-ops without settings" do
    bare = Ops::ErrorNotifier.new(settings: nil)
    bare.ses_client = @client

    bare.report(@error, handled: false, severity: :error, context: {})

    assert_empty @client.api_requests
  end

  test "never raises when SES delivery fails" do
    @client.stub_responses(:send_email, "MessageRejected")

    assert_nothing_raised do
      @notifier.report(@error, handled: false, severity: :error, context: {})
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/ops/error_notifier_test.rb`
Expected: FAIL — `uninitialized constant Ops::ErrorNotifier`.

- [ ] **Step 3: Implement the notifier**

Create `app/models/ops/error_notifier.rb`:

```ruby
# Emails unhandled exceptions to the operator through dedicated ops SES
# credentials (deliberately not a tenant Source). Subscribed to Rails.error in
# production; silent when the ops credentials are absent. Accepted trade-off:
# a total SES outage also silences alerts — uptime monitoring covers that hole.
class Ops::ErrorNotifier
  THROTTLE_WINDOW = 10.minutes

  attr_writer :ses_client

  def initialize(settings: Rails.application.credentials.ops)
    @settings = settings
  end

  def report(error, handled:, severity:, context: {}, source: nil)
    return if handled || settings.blank? || throttled?(error)

    ses_client.send_email(content: { raw: { data: build_message(error, context, source).to_s } })
  rescue => notifier_error
    Rails.logger.error("Ops::ErrorNotifier failed: #{notifier_error.class}: #{notifier_error.message}")
  end

  private
    attr_reader :settings

    def throttled?(error)
      !Rails.cache.write("ops_error_notifier/#{error.class.name}", true,
        unless_exist: true, expires_in: THROTTLE_WINDOW)
    end

    def build_message(error, context, source)
      Mail.new.tap do |message|
        message.from = settings[:from]
        message.to = settings[:to]
        message.subject = "[Departures] #{error.class}: #{error.message.to_s.truncate(120)}"
        message.body = <<~BODY
          #{error.class}: #{error.message}

          Source:  #{source || "unknown"}
          Context: #{context.inspect}

          #{Array(error.backtrace).first(20).join("\n")}
        BODY
      end
    end

    def ses_client
      @ses_client ||= Aws::SESV2::Client.new(region: settings[:region],
        credentials: Aws::Credentials.new(settings[:aws_access_key_id], settings[:aws_secret_access_key]),
        stub_responses: Rails.env.test?)
    end
end
```

Note the guard-clause line at the start of `report` is the only conditional exit (style §5.1: guards OK at method start before a non-trivial body).

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/models/ops/error_notifier_test.rb`
Expected: PASS (6 tests).

- [ ] **Step 5: Subscribe in production**

Create `config/initializers/error_reporting.rb`:

```ruby
# Unhandled request and job exceptions flow through the Rails error reporter
# (ActionDispatch executor + Active Job both report unhandled errors since 7.1).
# Alert the operator by email in production only.
Rails.application.config.after_initialize do
  if Rails.env.production?
    Rails.error.subscribe(Ops::ErrorNotifier.new)
  end
end
```

- [ ] **Step 6: Full suite + rubocop, commit**

Run: `bin/rails test && bin/rubocop` → green

```bash
git add app/models/ops/error_notifier.rb config/initializers/error_reporting.rb test/models/ops/error_notifier_test.rb
git commit -m "feat: Ops::ErrorNotifier — throttled error alerts via dedicated ops SES credentials"
```

---

### Task 6: Content-Security-Policy + force_ssl

**Files:**
- Modify: `config/initializers/content_security_policy.rb` (currently all commented)
- Modify: `config/environments/production.rb:27-34,61`
- Test: `test/controllers/content_security_policy_test.rb` (create)

**Interfaces:**
- Consumes: `EmailsController::PREVIEW_CSP` (existing constant — the preview action sets `response.headers["Content-Security-Policy"]` itself, and Rails' CSP middleware skips responses that already carry the header); `csp_meta_tag` already in the layout (Turbo reads the nonce from it for its injected progress-bar `<style>`); `javascript_importmap_tags` (importmap-rails noncifies its inline tags when nonce directives are configured).
- Produces: global CSP on every response except `emails#preview`.

- [ ] **Step 1: Write the failing tests**

Create `test/controllers/content_security_policy_test.rb`:

```ruby
require "test_helper"

class ContentSecurityPolicyTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
  end

  test "dashboard responses carry the global nonce-based policy" do
    get emails_url

    policy = response.headers["Content-Security-Policy"]
    assert_includes policy, "default-src 'self'"
    assert_includes policy, "frame-ancestors 'none'"
    assert_includes policy, "object-src 'none'"
    assert_match(/script-src 'self' 'nonce-[^']+'/, policy)
    assert_match(/style-src 'self' 'nonce-[^']+'/, policy)
  end

  test "email preview keeps its own stricter policy" do
    get preview_email_url(emails(:acme_delivered))

    assert_equal EmailsController::PREVIEW_CSP, response.headers["Content-Security-Policy"]
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/content_security_policy_test.rb`
Expected: first test FAILS (no CSP header yet); second may already pass.

- [ ] **Step 3: Enable the policy**

Replace the commented block in `config/initializers/content_security_policy.rb` with:

```ruby
# Global policy for the dashboard. The email preview endpoint sets its own
# stricter per-response header (EmailsController::PREVIEW_CSP); the CSP
# middleware leaves responses that already carry the header untouched.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src  :self
    policy.style_src   :self
    policy.img_src     :self, :data
    policy.font_src    :self
    policy.connect_src :self
    policy.frame_src   :self
    policy.object_src  :none
    policy.frame_ancestors :none
    policy.base_uri    :self
    policy.form_action :self
  end

  # Nonces for the importmap inline tags and Turbo's injected progress-bar
  # style (Turbo picks the nonce up from csp_meta_tag in the layout).
  config.content_security_policy_nonce_generator = ->(request) do
    request.session.id.to_s.presence || SecureRandom.base64(16)
  end
  config.content_security_policy_nonce_directives = %w[script-src style-src]
end
```

Notes: `frame_src :self` keeps the preview iframe loadable (its src is same-origin); `frame_ancestors :none` on dashboard pages coexists with the preview response's own `X-Frame-Options: SAMEORIGIN` because the preview response carries its own CSP.

- [ ] **Step 4: Run the CSP tests, then verify in the browser**

Run: `bin/rails test test/controllers/content_security_policy_test.rb` → PASS

Then `bin/dev`, sign in, and click through activity, an email inspector drawer + preview iframe, a form submit, and a live Turbo Stream update. The browser console must show **zero CSP violation reports**. Known risk spots: the importmap `<script type="importmap">` tag and Turbo's progress bar style — both should carry nonces. If a violation appears, fix the offending tag (add an explicit `nonce: true`), never widen the policy to `unsafe-inline`.

- [ ] **Step 5: Enable force_ssl in production config**

In `config/environments/production.rb` uncomment/set:

```ruby
  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint —
  # kamal-proxy probes /up over plain HTTP inside the Docker network.
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }
```

and set the mailer host (line 61) to the real domain:

```ruby
  config.action_mailer.default_url_options = { host: "<APP_DOMAIN>" }
```

- [ ] **Step 6: Full suite + rubocop, boot check, commit**

Run: `bin/rails test && bin/rubocop` → green
Run: `RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 bin/rails runner "puts :booted"` → prints `booted` (catches initializer typos under production eager load).

```bash
git add config/initializers/content_security_policy.rb config/environments/production.rb test/controllers/content_security_policy_test.rb
git commit -m "feat: enforce nonce-based CSP and force_ssl (deferred from phase 8)"
```

---

### Task 7: Kamal deployment configuration

**Files:**
- Modify: `config/deploy.yml`
- Modify: `.kamal/secrets`

**Interfaces:**
- Consumes: `<VPS_IP>`, `<APP_DOMAIN>`, ghcr PAT (execution inputs).
- Produces: a deployable Kamal config used by Task 10.

- [ ] **Step 1: Fill in deploy.yml**

Replace the placeholder sections of `config/deploy.yml` (leave `service`, `aliases`, `volumes`, `asset_path`, `builder` as they are):

```yaml
service: departures

image: jorgegorka/departures

servers:
  web:
    - <VPS_IP>
  job:
    hosts:
      - <VPS_IP>
    cmd: bin/jobs

proxy:
  ssl: true
  host: <APP_DOMAIN>

registry:
  server: ghcr.io
  username: jorgegorka
  password:
    - KAMAL_REGISTRY_PASSWORD

env:
  secret:
    - RAILS_MASTER_KEY
```

- [ ] **Step 2: Add the registry secret**

In `.kamal/secrets` ensure both lines exist (the file passes env through; it is git-tracked but contains no literal secrets):

```bash
KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD
RAILS_MASTER_KEY=$(cat config/master.key)
```

- [ ] **Step 3: Validate the config renders**

Run: `bin/kamal config`
Expected: full resolved config printed, no errors — `hosts: [<VPS_IP>]`, `proxy` with `ssl: true`, registry `ghcr.io`.

- [ ] **Step 4: Commit**

```bash
git add config/deploy.yml .kamal/secrets
git commit -m "chore: kamal config for production — ghcr registry, SSL proxy, web+job roles"
```

---

### Task 8: Backup script + backup/restore runbook

**Files:**
- Create: `bin/backup` (executable)
- Create: `docs/ops/backup-and-restore.md`

**Interfaces:**
- Consumes: the Kamal volume `departures_storage` (host path `/var/lib/docker/volumes/departures_storage/_data`, holding `production.sqlite3`, `production_queue.sqlite3`, `production_cache.sqlite3`, `production_cable.sqlite3`, and `emails/` with the `.eml` archive); `sqlite3` and `rclone` installed on the host.
- Produces: dated snapshots under `<rclone-remote>/<YYYY-MM-DD>/` with 30-day retention.

Only `production.sqlite3` and `production_queue.sqlite3` are backed up — cache and cable are disposable and recreated on boot.

- [ ] **Step 1: Write the script**

Create `bin/backup`:

```bash
#!/usr/bin/env bash
# Nightly Departures backup. Runs on the HOST (not in the container) via cron.
# Requires: sqlite3, rclone (with a remote configured — see docs/ops/backup-and-restore.md).
set -euo pipefail

VOLUME="${DEPARTURES_VOLUME:-/var/lib/docker/volumes/departures_storage/_data}"
REMOTE="${DEPARTURES_BACKUP_REMOTE:-departures-backups:departures-backups}"
RETENTION="${DEPARTURES_BACKUP_RETENTION:-30d}"
STAMP="$(date -u +%Y-%m-%d)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Consistent online copies of the databases that matter (cache/cable are disposable).
for db in production production_queue; do
  sqlite3 "$VOLUME/${db}.sqlite3" ".backup '$WORKDIR/${db}.sqlite3'"
done

# Archived MIME messages.
tar -czf "$WORKDIR/emails.tar.gz" -C "$VOLUME" emails

rclone copy "$WORKDIR" "$REMOTE/$STAMP"

# Prune snapshots past retention, then drop the emptied date directories.
rclone delete "$REMOTE" --min-age "$RETENTION"
rclone rmdirs "$REMOTE" --leave-root

echo "backup $STAMP complete: $(rclone size "$REMOTE/$STAMP")"
```

Run: `chmod +x bin/backup`

- [ ] **Step 2: Lint it**

Run: `bash -n bin/backup`
Expected: no output (syntax OK). If `shellcheck` is installed, run `shellcheck bin/backup` and fix any findings.

- [ ] **Step 3: Write the runbook**

Create `docs/ops/backup-and-restore.md`:

```markdown
# Backup & Restore

Nightly host-cron snapshots of the SQLite databases and the `.eml` archive to
S3-compatible object storage via rclone. RPO: 24 h (accepted in the Phase 9 spec).

## One-time host setup

1. `apt-get install -y sqlite3 rclone`
2. `rclone config` — create a remote named `departures-backups` pointing at the
   S3-compatible provider (type `s3`, provider/endpoint/keys per account), and
   create the `departures-backups` bucket.
3. Copy the script: `scp bin/backup root@<VPS_IP>:/usr/local/bin/departures-backup`
   (re-copy whenever `bin/backup` changes — it is versioned in the repo, executed on the host).
4. Crontab (`crontab -e` as root):

       15 3 * * * /usr/local/bin/departures-backup >> /var/log/departures-backup.log 2>&1

5. Verify the first run manually: `/usr/local/bin/departures-backup` then
   `rclone ls departures-backups:departures-backups`.

Cron mails/logs handle script failures (`set -euo pipefail` — any failing step
exits non-zero). This is deliberately independent of the app's error notifier.

## Snapshot layout

    <bucket>/<YYYY-MM-DD>/production.sqlite3
    <bucket>/<YYYY-MM-DD>/production_queue.sqlite3
    <bucket>/<YYYY-MM-DD>/emails.tar.gz

Retention: 30 days (pruned by the script).

## Restore procedure

1. Download: `rclone copy departures-backups:departures-backups/<DATE> /root/restore/<DATE>`
2. Integrity check BEFORE touching production:
   `sqlite3 /root/restore/<DATE>/production.sqlite3 "PRAGMA integrity_check;"` → must print `ok`.
   Spot-check: `sqlite3 /root/restore/<DATE>/production.sqlite3 "SELECT count(*) FROM emails;"`
3. Stop the app: `bin/kamal app stop` (from the dev machine).
4. On the host, swap the files in
   `/var/lib/docker/volumes/departures_storage/_data/`:
   move the live `production.sqlite3` (and `-wal`/`-shm` siblings, if present) aside,
   copy the restored file in; same for `production_queue.sqlite3`;
   `tar -xzf emails.tar.gz -C /var/lib/docker/volumes/departures_storage/_data/` to restore the archive.
5. Start the app: `bin/kamal app boot`. Verify `/up`, sign in, open the activity page.

## Restore drill (run at phase close and after any script change)

Steps 1–2 only, against last night's snapshot, in a scratch directory. Record
the date and `PRAGMA integrity_check` output in the phase-close notes.
```

- [ ] **Step 4: Commit**

```bash
git add bin/backup docs/ops/backup-and-restore.md
git commit -m "feat: nightly host-cron backup script and backup/restore runbook"
```

---

### Task 9: Monitoring runbook + ops credentials

**Files:**
- Create: `docs/ops/monitoring.md`
- Modify: production credentials (`bin/rails credentials:edit`) — not a git artifact

**Interfaces:**
- Consumes: `Ops::ErrorNotifier` settings contract from Task 5 (`credentials.ops`: `aws_access_key_id`, `aws_secret_access_key`, `region`, `from`, `to`).
- Produces: live alerting + uptime coverage for Task 10's checklist.

- [ ] **Step 1: Write the runbook**

Create `docs/ops/monitoring.md`:

```markdown
# Monitoring

## Uptime

External monitor pinging `https://<APP_DOMAIN>/up` every 5 minutes
(UptimeRobot free tier or equivalent; HTTP monitor, keyword optional, alert
to Jorge's email). `/up` is excluded from the force_ssl redirect and from
request logs, and reports 200 only when the app boots and connects to its
databases.

## Error alerts

`Ops::ErrorNotifier` (subscribed to `Rails.error` in production) emails
unhandled request/job exceptions through dedicated ops SES credentials —
at most one email per error class per 10 minutes. Configuration lives in
Rails credentials under `ops:`; if the key is absent the notifier is silent.

    ops:
      aws_access_key_id: <IAM key with ses:SendRawEmail only>
      aws_secret_access_key: <secret>
      region: <SES region>
      from: <verified sender, e.g. alerts@APP_DOMAIN>
      to: <Jorge's address>

Accepted trade-off (Phase 9 spec): a total SES outage also silences alerts;
the uptime monitor is the independent backstop.

## Where to look when something is wrong

- `bin/kamal logs` / `bin/kamal logs -r job` — app and worker logs.
- `bin/kamal console` — production Rails console.
- `/var/log/departures-backup.log` on the host — backup runs.
```

- [ ] **Step 2: Add the ops credentials (needs the real IAM pair)**

Run: `bin/rails credentials:edit` and add the `ops:` block from the runbook with real values. The `from` address must be SES-verified in that region (verify it in the SES console first if needed).

- [ ] **Step 3: Commit the runbook**

```bash
git add docs/ops/monitoring.md
git commit -m "docs: monitoring runbook — uptime ping and ops error-alert credentials"
```

---

### Task 10: Deploy, verify, drill, close the phase

**Files:**
- Modify: `docs/plans/departures-execution-plan.md` (Phase 9 status section)

**Interfaces:**
- Consumes: everything above.
- Produces: a running production service.

This task is mostly manual host/console work driven from the dev machine. Prerequisites on the VPS: Docker installed, ports 80/443 open, DNS A record for `<APP_DOMAIN>` → `<VPS_IP>` already propagated.

- [ ] **Step 1: First deploy**

```bash
export KAMAL_REGISTRY_PASSWORD=<ghcr PAT>
bin/kamal setup
```

Expected: image builds (amd64), pushes to ghcr.io, kamal-proxy boots with a Let's Encrypt cert, web + job containers healthy.

- [ ] **Step 2: Verification checklist (record each result)**

1. `curl -s -o /dev/null -w "%{http_code}" https://<APP_DOMAIN>/up` → `200`; certificate valid in the browser.
2. `curl -s -o /dev/null -w "%{http_code}" http://<APP_DOMAIN>/` → `301` redirect to https (`force_ssl` live). Response headers include `Strict-Transport-Security` and `Content-Security-Policy`.
3. Register the first user (registration is open while `User.none?`), complete onboarding: workspace → source (live SES credentials) → domain → API key.
4. Real send: `POST https://<APP_DOMAIN>/api/emails` with the API key → 202, message arrives in a real inbox with the `X-Departures-Id` header.
5. SNS wiring: in the AWS console, point the SES configuration-set event destination / SNS subscription at `https://<APP_DOMAIN>/api/webhooks/ses/<webhook_token>` (token from the source page). The `SubscriptionConfirmation` auto-confirms (subscription shows Confirmed); the delivery event for the test send lands — email status advances and the activity dashboard updates live in a second browser window.
6. Job role healthy: `bin/kamal logs -r job` shows Solid Queue polling and the send job processed.
7. Error notifier: from `bin/kamal console`, run `Ops::ErrorNotifier.new.report(RuntimeError.new("phase 9 alert test"), handled: false, severity: :error)` → alert email arrives at the ops `to:` address.
8. Uptime monitor created against `https://<APP_DOMAIN>/up` and showing Up.

- [ ] **Step 3: Backup setup + restore drill**

Follow `docs/ops/backup-and-restore.md` one-time setup, run the script manually, confirm the snapshot with `rclone ls`, then run the restore drill (download + `PRAGMA integrity_check` → `ok`, spot-check `SELECT count(*) FROM emails;`). Record outputs.

- [ ] **Step 4: Update the master plan and close**

Add to `docs/plans/departures-execution-plan.md` after the Phase 8 section:

```markdown
### Phase 9 — Production readiness (complete)

Spec: **`docs/superpowers/specs/2026-07-12-phase-9-production-readiness-design.md`**. Detailed plan: **`docs/plans/phase-9-production-readiness-plan.md`**.

Delivered: Kamal production deploy (<APP_DOMAIN> on the VPS, ghcr.io image, kamal-proxy + Let's Encrypt, web + job roles, persistent storage volume); `force_ssl`/`assume_ssl` + nonce-based CSP with the email-preview per-response carve-out; nightly host-cron backups (`bin/backup`: sqlite3 online backup of production + queue DBs, `.eml` tar, rclone to object storage, 30-day retention) with a tested restore drill; `Ops::ErrorNotifier` (Rails.error subscriber, dedicated ops SES credentials, 10-minute per-error-class throttle) + external uptime monitor on `/up`; Phase 8 follow-ups cleared (2FA re-enrollment guard, audit preload cleanup, audit-row tests for 5 actions, prune wiring test). Runbooks: `docs/ops/backup-and-restore.md`, `docs/ops/monitoring.md`.
```

- [ ] **Step 5: Final green + commit**

Run: `bin/rails test && bin/rubocop` → green

```bash
git add docs/plans/departures-execution-plan.md
git commit -m "docs: phase 9 (production readiness) status"
```

Then request a phase-close code review per Section C of the execution plan (superpowers:requesting-code-review) against the spec and both standards docs.

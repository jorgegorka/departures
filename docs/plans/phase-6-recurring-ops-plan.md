# Phase 6 — Recurring Work, Retention & Ops Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recurring quota syncs and retention pruning as Solid Queue recurring jobs, a dedicated Kamal `job` role, and the end-to-end smoke test that proves the whole platform loop (onboard → send → SNS bounce → suppression → live broadcast → blocked resend).

**Architecture:** All pruning/sync logic lives as class methods on the models (`Source.sync_all_quotas` already exists; this phase adds `Email.prune_expired`, `WebhookLog.prune`, `WebhookDelivery.prune` — `IdempotencyKey.prune_expired` and `Invitation.prune_expired` already exist). Jobs are 3–6-line wrappers (`SyncQuotasJob`, `PruneRetentionJob`) scheduled in `config/recurring.yml`. The smoke test is a single integration test driving real HTTP endpoints with stubbed AWS clients.

**Tech Stack:** Rails 8.1, SQLite, Solid Queue (recurring tasks via fugit schedules), Minitest + fixtures, `aws-sdk-sesv2` stubbed clients, Kamal.

## Global Constraints

- Default integer primary keys. No new gems (fugit already ships with solid_queue; `csv` and `kamal` are already in the Gemfile).
- Bang methods only when a non-bang counterpart exists — all new methods are bang-less (`prune`, `prune_expired`).
- Batch deletion uses `in_batches` (SQLite lock hygiene — master plan risk #3).
- Never pass workspace as a job argument (the ActiveJob extension captures `Current.workspace`; recurring jobs run with no workspace, which the extension tolerates).
- Jobs delegate to synchronous model methods (`_now/_later` pattern, patterns §4.4); logic is tested through the model method, scheduling through config.
- AWS is never hit for real: `Source#ses_client` builds with `stub_responses: true` in test, and tests needing specific responses stub `Aws::SESV2::Client.new` at class level.
- `Current.session = sessions(:name)` in every model-test setup touching lambda association defaults (patterns gotcha §7.3.1).
- Expanded conditionals over guard clauses; private methods indented under `private` with no blank line after the modifier (§5.1).
- `bin/rails test` and `bin/rubocop` green at the end of every task.

**Standards to re-read per task type (Section C.3 of the master plan):** model tasks → patterns Part 2 + §5.1; job tasks → §4.4–4.5; the smoke test task → the master plan's Verification section.

**Facts about the current codebase this plan relies on** (verified 2026-07-10):

- `Source.sync_all_quotas`, `Source#sync_quota`, `IdempotencyKey.prune_expired`, `Invitation.prune_expired` already exist — do NOT re-implement them.
- `Email::MimeStore.delete(email)` removes the archived `.eml` (no-op when `mime_path` blank); `Email::MimeStore.root` resolves to `tmp/storage/emails` in test (`config/environments/test.rb:58`).
- `Email` has `dependent: :destroy` on recipients, attachments, idempotency_keys, and events — `email.destroy` cascades cleanly.
- `sources.retention_days` is a non-null positive integer (fixtures use 30).
- There are no `webhook_logs.yml` / `webhook_deliveries.yml` fixtures — absolute-count assertions on those tables are safe.
- `config/queue.yml` already declares queues `default,webhooks`. `config/recurring.yml` already has a `production:` block with `clear_solid_queue_finished_jobs`.
- No project-creation UI exists — workspaces get projects from fixtures or model calls.
- `WebhookDelivery` and `WebhookLog` have no dependent children; `delete_all` is safe.

---

### Task 1: `SyncQuotasJob`

**Files:**
- Create: `app/jobs/sync_quotas_job.rb`
- Test: `test/jobs/sync_quotas_job_test.rb`

**Interfaces:**
- Consumes: `Source.sync_all_quotas` (existing, `app/models/source/quota.rb:10`) — calls `sync_quota` on every source; `sync_quota` swallows SES/network errors and returns false, so the job never needs its own rescue.
- Produces: `SyncQuotasJob` (no arguments), referenced by name in `config/recurring.yml` (Task 4).

- [ ] **Step 1: Write the failing test**

```ruby
# test/jobs/sync_quotas_job_test.rb
require "test_helper"

class SyncQuotasJobTest < ActiveSupport::TestCase
  test "perform refreshes stale quotas for every source" do
    source = sources(:acme_production)
    source.update!(last_quota_checked_at: 2.days.ago)

    SyncQuotasJob.perform_now

    assert source.reload.quota_fresh?
  end
end
```

(`Source#ses_client` is built with `stub_responses: true` in the test env, so `get_account` returns canned data and `sync_quota` stamps `last_quota_checked_at` — no stubbing needed.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/jobs/sync_quotas_job_test.rb`
Expected: FAIL with `NameError: uninitialized constant SyncQuotasJob`

- [ ] **Step 3: Write the job**

```ruby
# app/jobs/sync_quotas_job.rb
class SyncQuotasJob < ApplicationJob
  queue_as :default

  def perform
    Source.sync_all_quotas
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/jobs/sync_quotas_job_test.rb`
Expected: PASS (1 runs, 1 assertions)

- [ ] **Step 5: Rubocop + full jobs suite, then commit**

Run: `bin/rubocop && bin/rails test test/jobs`
Expected: no offenses, all green

```bash
git add app/jobs/sync_quotas_job.rb test/jobs/sync_quotas_job_test.rb
git commit -m "feat: SyncQuotasJob delegating to Source.sync_all_quotas"
```

---

### Task 2: `Email.prune_expired` — retention pruning with MIME cleanup

**Files:**
- Modify: `app/models/email.rb` (add class method + scope; current file is ~100 lines, no concern extraction needed per Section A2)
- Test: `test/models/email_retention_test.rb` (new file — keeps the already-large `email_test.rb` focused)

**Interfaces:**
- Consumes: `Email::MimeStore.delete(email)` (existing); `sources.retention_days` column; `Email` `dependent: :destroy` associations.
- Produces: `Email.prune_expired` (no arguments, returns nothing meaningful), called by `PruneRetentionJob` (Task 4). Also `scope :retention_expired_for, ->(source)`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/email_retention_test.rb
require "test_helper"

class EmailRetentionTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    wipe_send_domain
    @source = sources(:acme_production) # retention_days: 30
  end

  test "prune_expired destroys emails past the source retention window, their children, and their archived MIME" do
    expired = create_email(subject: "Old", created_at: 31.days.ago)
    expired.recipients.create!(address: "old@example.com", kind: "to")
    expired.events.create!(event_type: "delivery", occurred_at: 31.days.ago)
    Email::MimeStore.write(expired, "MIME-Version: 1.0\r\n\r\nold")
    eml_path = Email::MimeStore.root.join(expired.mime_path)

    kept = create_email(subject: "Recent", created_at: 29.days.ago)

    assert eml_path.exist?

    Email.prune_expired

    assert_not Email.exists?(expired.id)
    assert_not eml_path.exist?
    assert_equal 0, EmailRecipient.where(email_id: expired.id).count
    assert_equal 0, EmailEvent.where(email_id: expired.id).count
    assert Email.exists?(kept.id)
  end

  test "prune_expired applies each source's own retention window" do
    @source.update!(retention_days: 7)
    long_retention = sources(:globex_production) # retention_days: 30, other workspace

    short_lived = create_email(subject: "Short window", created_at: 8.days.ago)
    long_lived = Email.create!(project: long_retention.project, source: long_retention,
      from: "hello@globex.com", subject: "Long window", html_body: "<p>hi</p>", created_at: 8.days.ago)

    Email.prune_expired

    assert_not Email.exists?(short_lived.id)
    assert Email.exists?(long_lived.id)
  end

  test "prune_expired leaves emails without an archived MIME untouched by the file cleanup" do
    expired = create_email(subject: "No file", created_at: 31.days.ago)
    assert_nil expired.mime_path

    Email.prune_expired

    assert_not Email.exists?(expired.id)
  end

  private
    def create_email(subject:, created_at:)
      Email.create!(project: @source.project, source: @source, from: "hello@acme.com",
        subject: subject, html_body: "<p>hi</p>", created_at: created_at)
    end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/email_retention_test.rb`
Expected: FAIL with `NoMethodError: undefined method 'prune_expired' for class Email`

- [ ] **Step 3: Implement on `Email`**

In `app/models/email.rb`, add the scope with the other scopes (after `scope :preloaded`) and the class method after `def self.to_csv`:

```ruby
  scope :retention_expired_for, ->(source) { where(source: source, created_at: ...source.retention_days.days.ago) }
```

```ruby
  # Destroys per record (not delete_all) so dependent rows cascade and the
  # archived .eml comes off disk; small batches keep SQLite write locks short.
  def self.prune_expired
    Source.find_each do |source|
      retention_expired_for(source).in_batches(of: 100) do |batch|
        batch.each do |email|
          Email::MimeStore.delete(email)
          email.destroy
        end
      end
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/email_retention_test.rb`
Expected: PASS (3 runs)

- [ ] **Step 5: Rubocop + models suite, then commit**

Run: `bin/rubocop && bin/rails test test/models`
Expected: green

```bash
git add app/models/email.rb test/models/email_retention_test.rb
git commit -m "feat: Email.prune_expired honors per-source retention and deletes archived MIME"
```

---

### Task 3: `WebhookLog.prune` and `WebhookDelivery.prune`

**Files:**
- Modify: `app/models/webhook_log.rb` (add constant + class method above `#process`)
- Modify: `app/models/webhook_delivery.rb` (add constant + class method above `#deliver`)
- Test: `test/models/webhook_log_test.rb` (append), `test/models/webhook_delivery_test.rb` (append)

**Interfaces:**
- Produces: `WebhookLog.prune` and `WebhookDelivery.prune` (no arguments; delete rows older than 30 days), called by `PruneRetentionJob` (Task 4). Each model gains `PRUNE_AFTER = 30.days`.

- [ ] **Step 1: Write the failing tests**

Append to `test/models/webhook_log_test.rb` (inside the existing test class; its setup already sets `Current.session = sessions(:owner)`):

```ruby
  test "prune deletes logs older than the retention window and keeps newer ones" do
    old_log = WebhookLog.create!(source: sources(:acme_production), message_type: "Notification",
      payload: { "Type" => "Notification" }, created_at: 31.days.ago)
    recent_log = WebhookLog.create!(source: sources(:acme_production), message_type: "Notification",
      payload: { "Type" => "Notification" }, created_at: 29.days.ago)

    WebhookLog.prune

    assert_not WebhookLog.exists?(old_log.id)
    assert WebhookLog.exists?(recent_log.id)
  end
```

Append to `test/models/webhook_delivery_test.rb` (its setup already sets `Current.session = sessions(:owner)`):

```ruby
  test "prune deletes deliveries older than the retention window and keeps newer ones" do
    endpoint = webhook_endpoints(:acme_all)
    old_delivery = endpoint.deliveries.create!(event_type: "delivery", payload: {}, created_at: 31.days.ago)
    recent_delivery = endpoint.deliveries.create!(event_type: "delivery", payload: {}, created_at: 29.days.ago)

    WebhookDelivery.prune

    assert_not WebhookDelivery.exists?(old_delivery.id)
    assert WebhookDelivery.exists?(recent_delivery.id)
  end
```

(`endpoint.deliveries` is `WebhookEndpoint has_many :deliveries, class_name: "WebhookDelivery"`; the `acme_all` fixture subscribes to all events.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/webhook_log_test.rb test/models/webhook_delivery_test.rb`
Expected: the two new tests FAIL with `NoMethodError: undefined method 'prune'`; every pre-existing test still passes.

- [ ] **Step 3: Implement**

In `app/models/webhook_log.rb`, directly under the `enum :status` declaration:

```ruby
  PRUNE_AFTER = 30.days

  def self.prune
    where(created_at: ...PRUNE_AFTER.ago).in_batches.delete_all
  end
```

In `app/models/webhook_delivery.rb`, alongside the other constants (`MAX_RESPONSE_BODY`, `TIMEOUT`):

```ruby
  PRUNE_AFTER = 30.days
```

and above `def deliver`:

```ruby
  def self.prune
    where(created_at: ...PRUNE_AFTER.ago).in_batches.delete_all
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/models/webhook_log_test.rb test/models/webhook_delivery_test.rb`
Expected: PASS

- [ ] **Step 5: Rubocop, then commit**

Run: `bin/rubocop`
Expected: no offenses

```bash
git add app/models/webhook_log.rb app/models/webhook_delivery.rb \
  test/models/webhook_log_test.rb test/models/webhook_delivery_test.rb
git commit -m "feat: 30-day pruning for webhook logs and deliveries"
```

---

### Task 4: `PruneRetentionJob` + recurring schedule

**Files:**
- Create: `app/jobs/prune_retention_job.rb`
- Modify: `config/recurring.yml`
- Test: `test/jobs/prune_retention_job_test.rb`, `test/config/recurring_schedule_test.rb`

**Interfaces:**
- Consumes: `Email.prune_expired` (Task 2), `WebhookLog.prune` / `WebhookDelivery.prune` (Task 3), `IdempotencyKey.prune_expired` (existing), `Invitation.prune_expired` (existing), `SyncQuotasJob` (Task 1).
- Produces: `PruneRetentionJob` (no arguments) and the production recurring schedule entries `sync_quotas` (every 4 hours) and `prune_retention` (daily).

- [ ] **Step 1: Write the failing job test**

```ruby
# test/jobs/prune_retention_job_test.rb
require "test_helper"

class PruneRetentionJobTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    wipe_send_domain
  end

  test "perform prunes every retention-bound table in one pass" do
    source = sources(:acme_production)
    expired_email = Email.create!(project: source.project, source: source, from: "hello@acme.com",
      subject: "Old", html_body: "<p>old</p>", created_at: 31.days.ago)
    fresh_email = Email.create!(project: source.project, source: source, from: "hello@acme.com",
      subject: "New", html_body: "<p>new</p>")
    old_log = WebhookLog.create!(source: source, message_type: "Notification",
      payload: {}, created_at: 31.days.ago)
    expired_idempotency = IdempotencyKey.create!(api_key: api_keys(:acme_full), email: fresh_email,
      key: "prune-test-key", fingerprint: "f", expires_at: 1.hour.ago)
    expired_invitation = Invitation.create!(workspace: workspaces(:acme), email: "late@example.com",
      role: "member", expires_at: 1.day.ago)

    PruneRetentionJob.perform_now

    assert_not Email.exists?(expired_email.id)
    assert Email.exists?(fresh_email.id)
    assert_not WebhookLog.exists?(old_log.id)
    assert_not IdempotencyKey.exists?(expired_idempotency.id)
    assert_not Invitation.exists?(expired_invitation.id)
  end
end
```

(`acme_full` exists in `test/fixtures/api_keys.yml`; `"member"` is a valid role in `Workspace::Roles::ROLE_CAPABILITIES`. `Invitation#set_expiry` uses `||=`, so the past `expires_at` sticks.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/jobs/prune_retention_job_test.rb`
Expected: FAIL with `NameError: uninitialized constant PruneRetentionJob`

- [ ] **Step 3: Write the job**

```ruby
# app/jobs/prune_retention_job.rb
class PruneRetentionJob < ApplicationJob
  queue_as :default

  def perform
    Email.prune_expired
    WebhookLog.prune
    WebhookDelivery.prune
    IdempotencyKey.prune_expired
    Invitation.prune_expired
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/jobs/prune_retention_job_test.rb`
Expected: PASS

- [ ] **Step 5: Write the failing schedule-config test**

The `production:` block of `recurring.yml` never loads in the test env, so a config test is the only automated guard against a typo'd class name or unparseable schedule:

```ruby
# test/config/recurring_schedule_test.rb
require "test_helper"

class RecurringScheduleTest < ActiveSupport::TestCase
  test "every production recurring task names a real job or command and a parseable schedule" do
    tasks = YAML.load_file(Rails.root.join("config", "recurring.yml"))["production"]

    assert_includes tasks.keys, "sync_quotas"
    assert_includes tasks.keys, "prune_retention"

    tasks.each do |name, task|
      assert task["class"].present? || task["command"].present?, "#{name} needs a class or command"
      if task["class"]
        assert task["class"].constantize < ActiveJob::Base, "#{name} must name an ActiveJob class"
      end
      assert Fugit.parse(task["schedule"]), "#{name} schedule #{task["schedule"].inspect} must parse"
    end
  end
end
```

Run: `bin/rails test test/config/recurring_schedule_test.rb`
Expected: FAIL on the `assert_includes` (entries not yet added)

- [ ] **Step 6: Add the schedule entries**

`config/recurring.yml` becomes:

```yaml
production:
  clear_solid_queue_finished_jobs:
    command: "SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)"
    schedule: every hour at minute 12
  sync_quotas:
    class: SyncQuotasJob
    queue: default
    schedule: every 4 hours
  prune_retention:
    class: PruneRetentionJob
    queue: default
    schedule: every day at 3am
```

(Keep the commented `# examples:` header block at the top of the file as-is.)

- [ ] **Step 7: Run test to verify it passes**

Run: `bin/rails test test/config/recurring_schedule_test.rb`
Expected: PASS

- [ ] **Step 8: Rubocop + jobs suite, then commit**

Run: `bin/rubocop && bin/rails test test/jobs test/config`
Expected: green

```bash
git add app/jobs/prune_retention_job.rb config/recurring.yml \
  test/jobs/prune_retention_job_test.rb test/config/recurring_schedule_test.rb
git commit -m "feat: PruneRetentionJob and recurring schedule for quota sync and retention"
```

---

### Task 5: Kamal — dedicated `job` role

**Files:**
- Modify: `config/deploy.yml`

**Interfaces:**
- Produces: a `job` role running `bin/jobs` on the same host; Solid Queue leaves the Puma process. The `departures_storage:/rails/storage` volume (already present) persists SQLite DBs and the `.eml` archive across deploys. The master plan's "health `/up`" requirement is already satisfied by defaults: Rails 8 mounts `/up` and kamal-proxy health-checks it out of the box — no config change needed.

No automated test exists for deploy config; verification is rendering the config.

- [ ] **Step 1: Add the job role and stop running Solid Queue inside Puma**

In `config/deploy.yml`, change the `servers:` block from:

```yaml
servers:
  web:
    - 192.168.0.1
  # job:
  #   hosts:
  #     - 192.168.0.1
  #   cmd: bin/jobs
```

to:

```yaml
servers:
  web:
    - 192.168.0.1
  job:
    hosts:
      - 192.168.0.1
    cmd: bin/jobs
```

and in the `env: clear:` section DELETE the line (and its explanatory comment above it):

```yaml
    SOLID_QUEUE_IN_PUMA: true
```

Removing that line empties the `clear:` mapping; also remove the now-empty `clear:` key itself (Kamal rejects an empty clear key).

(The dedicated `job` container now runs the Solid Queue supervisor — including the recurring-task scheduler — so the web container must not also run it, or recurring jobs double-enqueue.)

- [ ] **Step 2: Verify the config still renders**

Run: `bin/kamal config | head -40`
Expected: rendered YAML showing both `web` and `job` roles under `servers`/`roles`. (If this errors on a missing `.kamal/secrets` entry, that's environment-local — fall back to `ruby -ryaml -e 'puts YAML.load_file("config/deploy.yml").fetch("servers").keys'` and expect `web job`.)

- [ ] **Step 3: Commit**

```bash
git add config/deploy.yml
git commit -m "ops: dedicated Kamal job role for Solid Queue, out of Puma"
```

---

### Task 6: Full-loop smoke test

**Files:**
- Create: `test/integration/full_loop_test.rb`

**Interfaces (all existing — this task writes only the test):**
- `POST /registration` (open while `User.none?`; `User.create_owner` bootstraps a workspace and signs in).
- `POST /sources`, `POST /api_keys` (renders one-time plaintext `dp_…` token in the response body), `POST /domains` — all `allow_unonboarded_access`.
- `POST /api/emails` with `Authorization: Bearer` (guardrails: unverified from-domain → 422 listing "domain is not verified").
- `SendEmailJob` → `Email::Deliverable#deliver` → `Aws::SESV2::Client#send_email` (stub at class level to control `message_id`).
- `POST /api/webhooks/ses/:webhook_token` with `Sns::MessageVerifier` stubbed authentic; `ProcessSesEventJob` → bounce ingestion, suppression, `[project, :activity]` refresh broadcast.
- `POST /onboarding/completion` marks the workspace onboarded (the resend controller sits behind the onboarding gate).
- `POST /emails/:email_id/resend` → `Email#resend` → blocked by suppression, alert "Email could not be resent — recipients may be suppressed."

- [ ] **Step 1: Write the smoke test**

```ruby
# test/integration/full_loop_test.rb
require "test_helper"
require "turbo/broadcastable/test_helper"

# End-to-end proof of the platform loop from the master plan's Verification
# section: onboard -> issue key -> API send through stubbed SES -> SNS bounce
# -> suppression + live broadcast -> resend to the suppressed address blocked.
class FullLoopTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include Turbo::Broadcastable::TestHelper

  class AuthenticVerifier
    def authentic?(_message)
      true
    end
  end

  SES_MESSAGE_ID = "ses-smoke-0001"
  RECIPIENT = "customer@example.com"

  test "an email round-trips from onboarding to a blocked resend" do
    wipe_workspace_records

    # Registration is open on an empty database and bootstraps workspace + session.
    post registration_url, params: { email_address: "founder@acme-smoke.com",
      password: "secret123456", password_confirmation: "secret123456" }
    assert_redirected_to root_url

    workspace = Workspace.sole
    # No project UI exists; the dashboard picks the workspace's first active project.
    project = workspace.projects.create!(name: "Smoke")

    # Onboarding step: add a source.
    post sources_url, params: { source: { name: "Production", environment: "production",
      region: "eu-west-1", retention_days: 30,
      aws_access_key_id: "AKIASMOKE", aws_secret_access_key: "smoke-secret" } }
    assert_redirected_to sources_url
    source = project.sources.sole

    # Onboarding step: issue an API key and capture the one-time plaintext.
    post api_keys_url, params: { api_key: { name: "Smoke key", scopes: [ "send", "read:activity" ] } }
    assert_response :success
    bearer = response.body[/dp_[A-Za-z0-9]{48}/]
    assert bearer, "the create view must reveal the plaintext key once"

    # Guardrail: sending from an unverified domain is refused.
    post "/api/emails", params: send_params, headers: auth(bearer), as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body["errors"].join(" "), "domain is not verified"

    # Onboarding step: add the domain. The canned SES stub cannot report
    # verified_for_sending_status, so verification flips at the model — the
    # SES provision/check flows are covered by the Phase 5 domain tests.
    post domains_url, params: { domain: { name: "acme-smoke.com" } }
    project.domains.sole.update!(status: "verified")

    # The send is now accepted and delivered through stubbed SES.
    post "/api/emails", params: send_params, headers: auth(bearer), as: :json
    assert_response :accepted
    email = project.emails.find_by!(public_id: response.parsed_body["id"])

    ses = Aws::SESV2::Client.new(stub_responses: true, region: "eu-west-1")
    ses.stub_responses(:send_email, message_id: SES_MESSAGE_ID)
    Aws::SESV2::Client.stub :new, ses do
      perform_enqueued_jobs only: SendEmailJob
    end

    assert email.reload.sent?
    assert_equal SES_MESSAGE_ID, email.ses_message_id

    # SES reports a permanent bounce via SNS; ingestion is enqueued.
    Sns::MessageVerifier.stub :new, AuthenticVerifier.new do
      post "/api/webhooks/ses/#{source.webhook_token}", params: bounce_notification.to_json,
        headers: { "Content-Type" => "text/plain" }
    end
    assert_response :ok

    # Processing advances the status, records the event, suppresses the
    # recipient, and refreshes the live activity stream.
    streams = capture_turbo_stream_broadcasts([ project, :activity ]) do
      perform_enqueued_jobs only: ProcessSesEventJob
    end
    assert_equal "refresh", streams.sole["action"]

    assert email.reload.bounced?
    assert_equal "permanent", email.bounce_type
    assert_equal [ "bounce" ], email.events.pluck(:event_type)
    assert_includes Suppression.covers?(project, [ RECIPIENT ]), RECIPIENT

    # Finish onboarding so the dashboard opens up, then the resend is blocked.
    post onboarding_completion_url
    assert workspace.reload.onboarded?

    assert_no_difference -> { Email.count } do
      post email_resend_url(email)
    end
    assert_redirected_to email_url(email)
    assert_match(/suppressed/, flash[:alert])
  end

  private
    def auth(bearer)
      { "Authorization" => "Bearer #{bearer}" }
    end

    def send_params
      { from: "hello@acme-smoke.com", to: [ RECIPIENT ],
        subject: "Smoke test", html: "<p>Hello</p>", text: "Hello" }
    end

    def bounce_notification
      message = JSON.parse(file_fixture("sns/bounce_permanent.json").read)
      message["mail"]["messageId"] = SES_MESSAGE_ID
      message["mail"]["destination"] = [ RECIPIENT ]
      message["bounce"]["bouncedRecipients"] = [ { "emailAddress" => RECIPIENT, "action" => "failed",
        "status" => "5.1.1", "diagnosticCode" => "smtp; 550 5.1.1 user unknown" } ]

      { "Type" => "Notification", "MessageId" => "sns-smoke-1",
        "TopicArn" => "arn:aws:sns:eu-west-1:123456789012:departures",
        "Message" => message.to_json, "Timestamp" => "2026-07-01T10:00:05.000Z",
        "SignatureVersion" => "1", "Signature" => "sig",
        "SigningCertURL" => "https://sns.eu-west-1.amazonaws.com/cert.pem" }
    end
end
```

Mechanics the implementer should know before debugging:

- `wipe_workspace_records` empties the whole graph (transactional tests roll it back), which both opens registration (`User.none?`) and makes `.sole` assertions safe.
- The first `POST /api/emails` triggers the quota guardrail: `EmailSubmission` calls `source.sync_quota`, which hits the source's own `stub_responses: true` client — no stubbing needed there.
- The class-level `Aws::SESV2::Client.stub :new, ses` is only needed around `perform_enqueued_jobs`, because the job deserializes a fresh `Source` whose memoized client can't be injected — this is the AGENTS.md-sanctioned stubbing seam.
- The broadcast is captured around job processing (not the webhook POST) because `Broadcastable#broadcast_activity` defers to `after_all_transactions_commit` inside `WebhookLog#process`.
- If `password` fails validation, check `User` for the minimum length used by the `sign_in_as` helper (`secret123456` matches the fixtures).

- [ ] **Step 2: Run the smoke test**

Run: `bin/rails test test/integration/full_loop_test.rb`
Expected: PASS (1 runs, ~18 assertions). If it fails, debug the failing leg against the controller/model files listed in Interfaces above — do not weaken assertions to force a pass.

- [ ] **Step 3: Rubocop + full suite, then commit**

Run: `bin/rubocop && bin/rails test`
Expected: green

```bash
git add test/integration/full_loop_test.rb
git commit -m "test: full-loop smoke test from onboarding to blocked resend"
```

---

### Task 7: Phase close — verification sweep + plan status

**Files:**
- Modify: `docs/plans/departures-execution-plan.md`

- [ ] **Step 1: Run the project-level verification greps from the master plan**

```bash
rg "def \w+!" app/            # expect: no hits (or only bang methods with non-bang counterparts)
bin/rubocop
bin/rails test
```

Expected: all green; the smoke test and the recurring/pruning tests all pass.

- [ ] **Step 2: Mark Phase 6 complete in the master plan**

In `docs/plans/departures-execution-plan.md`, change the Phase 6 heading block:

```markdown
### Phase 6 — Recurring work, retention, ops

Detailed plan: **docs/plans/phase-6-recurring-ops-plan.md** (complete).
```

(Insert the "Detailed plan" line directly under the `### Phase 6` heading, matching the Phase 2–5 format.)

- [ ] **Step 3: Commit**

```bash
git add docs/plans/departures-execution-plan.md
git commit -m "docs: phase 6 plan status"
```

- [ ] **Step 4: Request code review**

Per master plan Section C.4, run `superpowers:requesting-code-review` against `docs/patterns-and-best-practices.md`, `docs/style-guide.md`, and the Phase 6 test list (recurring jobs green, retention respects `retention_days` and deletes `.eml`s, smoke test mirrors the Verification section).

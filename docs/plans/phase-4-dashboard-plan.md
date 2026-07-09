# Phase 4 — Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Hotwire dashboard over the existing send/ingestion domain: live activity feed, metrics tiles with sparklines, email inspector with preview/raw/resend, suppression + bounce management with CSV exports, and a send-test form.

**Architecture:** All filtering/metrics/resend logic lives in models (scopes, a `Project::Metrics` presenter, an `Email::Resendable` concern). Controllers are thin and conventional; the activity feed subscribes to the `[project, :activity]` Turbo refresh broadcast that `Broadcastable` already emits on every status advance. All dashboard resources are top-level routes — `Current.project` is session-driven (no project URL param).

**Tech Stack:** Rails 8.1, SQLite, Hotwire (Turbo 8 morph refresh + Stimulus), Solid Cache, `mail` gem, hand-written CSS on the existing token system, stdlib `csv` (the one allowed gem addition).

## Global Constraints

- Integer primary keys. No new gems except `gem "csv"` (explicitly allowed by the master plan, Task 4.5 — Ruby 3.4 removed it from default gems).
- Thin RESTful controllers — no custom actions except the sanctioned read-only member GETs `preview`/`raw` on emails (master plan A3).
- Bang methods only with a non-bang counterpart. Expanded conditionals over guard clauses (guards OK only at the start of a non-trivial body). Method order: class → public (`initialize` first) → private, private methods in invocation order, indented under `private` with no blank line after the modifier.
- Dashboard controllers scope through `Current.workspace` / `Current.project` — cross-tenant access must 404 (`ActiveRecord::RecordNotFound`), never 403. Capability failures 403 via `authorize_capability!`.
- CSS: tokens only (no raw color values in feature CSS), new component CSS in the right `@layer` (`components` for reusable pieces, `modules` for feature CSS), logical properties, light + dark verified.
- Every task ends with `bin/rails test` and `bin/rubocop` green, then a commit on `next-phases`.
- **User decisions already made:** (a) add an `emails.bounce_type` column populated at SNS ingestion (not a JSON-join scope); (b) resend reconstructs attachments by re-parsing the archived `.eml`; (c) execute in this session after plan commit.

## Standards preludes (per Section C.3 of the master plan)

Before each task, re-read the named sections:

- **Tasks 1–3 (model work):** `docs/patterns-and-best-practices.md` Part 2 (+§5.1); master plan Section A2.
- **Task 4 (presenter + views):** patterns §3.4 + §5.1; style-guide tokens/inputs/buttons/dark-mode; **read the `dataviz` skill before writing sparkline/tile markup** (master plan 4.3 directive).
- **Tasks 5–9 (controllers + views):** patterns Part 4.1–4.3; style-guide (tokens, buttons, inputs, icons, dark mode); master plan A3/A7.

---

### Task 1: Phase-3 carry-over fixes

The phase-3 plan deferred five small hardening items to Phase 4 as prerequisites. They touch the ingestion/suppression paths every later task reads.

**Files:**
- Modify: `app/controllers/webhooks/ses_controller.rb`
- Modify: `app/models/email/ses_event.rb`
- Modify: `app/models/email/statuses.rb`
- Modify: `app/models/email/deliverable.rb`
- Modify: `app/models/suppression.rb`
- Test: `test/controllers/webhooks/ses_controller_test.rb`, `test/models/email/ses_event_test.rb`, `test/models/email/statuses_test.rb`, `test/models/suppression_test.rb`

**Interfaces:**
- Consumes: existing `Sns::MessageVerifier`, `Suppression.covers?`, `Email::Statuses#advance_to`.
- Produces: no API changes — behavior fixes only. Later tasks rely on `Suppression.covers?` using `normalize_value_for` and on `advance_to` keeping in-memory `updated_at` fresh.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/webhooks/ses_controller_test.rb` (match the file's existing setup helpers for posting payloads — reuse its signed-payload/fixture helpers rather than inventing new ones):

```ruby
test "a cert-fetch failure raised before the log exists still returns 503" do
  source = sources(:acme_production)
  failing_logs = Object.new
  def failing_logs.create!(**) = raise IOError, "disk full"

  source.stub :webhook_logs, failing_logs do
    Source.stub :find_by, source do
      post ses_webhooks_path(webhook_token: source.webhook_token),
        params: { "Type" => "Notification", "Message" => "{}" }.to_json,
        headers: { "CONTENT_TYPE" => "text/plain" }
    end
  end

  assert_response :service_unavailable
end
```

Append to `test/models/email/ses_event_test.rb`:

```ruby
test "recipients drops nil and blank addresses" do
  event = Email::SesEvent.new(
    "eventType" => "Bounce",
    "bounce" => { "bouncedRecipients" => [ { "emailAddress" => "real@example.com" }, {}, { "emailAddress" => "" } ] })

  assert_equal [ "real@example.com" ], event.recipients
end
```

Append to `test/models/email/statuses_test.rb` (reuse the file's existing setup/fixtures):

```ruby
test "a successful advance keeps the in-memory updated_at in sync with the row" do
  email = emails(:acme_welcome)

  email.mark_sending
  in_memory = email.updated_at

  assert_equal email.reload.updated_at.to_f, in_memory.to_f
end
```

Append to `test/models/suppression_test.rb`:

```ruby
test "covers? matches addresses through the model normalizer" do
  covered = Suppression.covers?(projects(:acme_default), [ "  BLOCKED@Example.COM " ])

  assert_equal [ "blocked@example.com" ], covered
end
```

- [ ] **Step 2: Run the new tests to verify they fail (updated_at and covers? ones must fail; note which already pass)**

Run: `bin/rails test test/controllers/webhooks/ses_controller_test.rb test/models/email/ses_event_test.rb test/models/email/statuses_test.rb test/models/suppression_test.rb`
Expected: the ses_controller test errors with `NoMethodError: undefined method 'update!' for nil`; the recipients test fails with `[ "real@example.com", nil, "" ]`; the updated_at test fails (stale in-memory timestamp); covers? may already pass for this input via the hand-rolled downcase — keep it as a pin regardless.

- [ ] **Step 3: Apply the five fixes**

`app/controllers/webhooks/ses_controller.rb` — nil-safe rescue (the log is nil when `create!` itself raised):

```ruby
  rescue *CERT_FETCH_ERRORS => error
    webhook_log&.update!(status: "failed", error: error.message)
    head :service_unavailable
```

`app/models/email/ses_event.rb` — filter nil/blank recipient entries; keep the case, filter once at the end:

```ruby
  def recipients
    addresses =
      case event_type
      when "bounce"
        Array(payload.dig("bounce", "bouncedRecipients")).map { |recipient| recipient["emailAddress"] }
      when "complaint"
        Array(payload.dig("complaint", "complainedRecipients")).map { |recipient| recipient["emailAddress"] }
      when "delivery"
        Array(payload.dig("delivery", "recipients"))
      else
        Array(payload.dig("mail", "destination"))
      end

    addresses.filter_map { |address| address.presence }
  end
```

`app/models/email/statuses.rb` — one captured `now` used in both the SQL and the in-memory mirror:

```ruby
    def advance_to(new_status, **attributes)
      now = Time.current
      advanced = self.class.where(id: id, status: lower_precedence_statuses(new_status))
        .update_all(status: new_status, updated_at: now, **attributes) == 1

      if advanced
        assign_attributes(status: new_status, updated_at: now, **attributes)
        changes_applied # update_all already persisted these — keep the record clean
        broadcast_activity
      else
        reload
      end

      advanced
    end
```

`app/models/email/deliverable.rb` — fix the stale comment only (no code change):

```ruby
    # Resolve the client before mark_sending: advance_to reloads on a rejected
    # write (e.g. a concurrent retry already advanced the row), which resets the
    # source association cache (and its memoized ses_client) — grab it first.
    client = source.ses_client
```

`app/models/suppression.rb` — `covers?` goes through the single normalization source of truth:

```ruby
    def covers?(project, addresses)
      normalized = Array(addresses).map { |address| normalize_value_for(:email, address.to_s) }
      active.where(project: project, email: normalized).pluck(:email)
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/webhooks/ses_controller_test.rb test/models/email/ses_event_test.rb test/models/email/statuses_test.rb test/models/suppression_test.rb`
Expected: PASS.

- [ ] **Step 5: Full suite + rubocop, commit**

```bash
bin/rails test && bin/rubocop
git add -A && git commit -m "fix: phase-3 carry-overs — nil-log rescue, recipient hardening, fresh updated_at, covers? normalizer"
```

---

### Task 2: `bounce_type` column + ingestion write + fixture expansion

**Files:**
- Create: `db/migrate/<timestamp>_add_bounce_type_to_emails.rb`
- Modify: `app/models/email/ses_event.rb`, `app/models/email/statuses.rb`, `app/models/webhook_log.rb`
- Modify: `test/fixtures/emails.yml`; Create: `test/fixtures/email_recipients.yml`, `test/fixtures/email_events.yml`
- Test: `test/models/email/ses_event_test.rb`, `test/models/webhook_log_test.rb`

**Interfaces:**
- Consumes: `Email::SesEvent#bounce?` / `#permanent_bounce?`, `WebhookLog#ingest_notification`, `Email::Statuses#apply_event`.
- Produces: `emails.bounce_type` string column (`"permanent"` / `"transient"` / nil); `Email::SesEvent#bounce_type` → `"permanent"`/`"transient"`/nil; `Email#apply_event(event_type, **attributes)` (attributes ride the same precedence-guarded UPDATE). Task 3's `hard_bounced`/`soft_bounced` scopes and Task 8's retry queue read `bounce_type`. Existing `bounced` rows keep `bounce_type: nil` — nil means unclassified and is deliberately excluded from `soft_bounced`, so retry never re-sends an unclassified bounce.

- [ ] **Step 1: Migration**

```ruby
class AddBounceTypeToEmails < ActiveRecord::Migration[8.1]
  def change
    add_column :emails, :bounce_type, :string
    add_index :emails, [ :project_id, :bounce_type ]
  end
end
```

Run: `bin/rails db:migrate` (then `git status` to confirm `db/schema.rb` updated).

- [ ] **Step 2: Write the failing tests**

Append to `test/models/email/ses_event_test.rb`:

```ruby
test "bounce_type maps SES bounceType to permanent or transient" do
  permanent = Email::SesEvent.new("eventType" => "Bounce", "bounce" => { "bounceType" => "Permanent" })
  transient = Email::SesEvent.new("eventType" => "Bounce", "bounce" => { "bounceType" => "Transient" })
  delivery  = Email::SesEvent.new("eventType" => "Delivery")

  assert_equal "permanent", permanent.bounce_type
  assert_equal "transient", transient.bounce_type
  assert_nil delivery.bounce_type
end
```

Append to `test/models/webhook_log_test.rb` (reuse its existing fixture-payload processing helpers — the file already processes `bounce_permanent` / `bounce_transient` / `delivery` SNS payloads):

```ruby
test "ingesting a permanent bounce records bounce_type on the email" do
  email = matched_email
  process_fixture("bounce_permanent")

  assert_equal "permanent", email.reload.bounce_type
end

test "ingesting a transient bounce records bounce_type on the email" do
  email = matched_email
  process_fixture("bounce_transient")

  assert_equal "transient", email.reload.bounce_type
end

test "non-bounce events leave bounce_type nil" do
  email = matched_email
  process_fixture("delivery")

  assert_nil email.reload.bounce_type
end
```

(If the helper names differ, mirror whatever the existing bounce tests in that file use.)

- [ ] **Step 3: Run to verify failure**

Run: `bin/rails test test/models/email/ses_event_test.rb test/models/webhook_log_test.rb`
Expected: FAIL — `bounce_type` method missing / column nil.

- [ ] **Step 4: Implement**

`app/models/email/ses_event.rb` — add below `permanent_bounce?`:

```ruby
  def bounce_type
    if bounce?
      permanent_bounce? ? "permanent" : "transient"
    end
  end
```

`app/models/email/statuses.rb` — let `apply_event` carry attributes into the same compare-and-set UPDATE (so `bounce_type` is only written when the status actually advances, atomically):

```ruby
  def apply_event(event_type, **attributes)
    status_for_event = EVENT_STATUSES[event_type.to_s]

    if status_for_event
      advance_to(status_for_event, **attributes)
    else
      false
    end
  end
```

`app/models/webhook_log.rb` — in `ingest_notification`, replace `email.apply_event(event.event_type)` with:

```ruby
          email.apply_event(event.event_type, **bounce_attributes(event))
```

and add a private method (in invocation order, after `record_events`):

```ruby
    def bounce_attributes(event)
      if event.bounce?
        { bounce_type: event.bounce_type }
      else
        {}
      end
    end
```

- [ ] **Step 5: Expand fixtures**

Replace `test/fixtures/emails.yml` with (keeps the existing `acme_welcome` row unchanged; every row needs explicit unique `public_id` because fixtures skip callbacks):

```yaml
acme_welcome:
  project: acme_default
  workspace: acme
  source: acme_production
  api_key: acme_full
  public_id: em_fixturewelcome000000001
  status: queued
  from: hello@acme.com
  subject: Welcome
  html_body: "<p>Welcome</p>"

acme_sent:
  project: acme_default
  workspace: acme
  source: acme_production
  public_id: em_fixturesent0000000001
  status: sent
  from: hello@acme.com
  subject: April invoice
  text_body: "Invoice attached"
  ses_message_id: fixture-sent-0001
  created_at: <%= 30.minutes.ago %>

acme_delivered:
  project: acme_default
  workspace: acme
  source: acme_production
  public_id: em_fixturedelivered000001
  status: delivered
  from: hello@acme.com
  subject: Welcome aboard
  html_body: "<p>Hi!</p>"
  ses_message_id: fixture-delivered-0001
  created_at: <%= 3.hours.ago %>

acme_opened:
  project: acme_default
  workspace: acme
  source: acme_production
  public_id: em_fixtureopened00000001
  status: opened
  from: hello@acme.com
  subject: Weekly digest
  html_body: "<p>News</p>"
  ses_message_id: fixture-opened-0001
  created_at: <%= 2.days.ago %>

acme_clicked:
  project: acme_default
  workspace: acme
  source: acme_production
  public_id: em_fixtureclicked0000001
  status: clicked
  from: hello@acme.com
  subject: Sale starts now
  html_body: "<p><a href='https://acme.com'>Shop</a></p>"
  ses_message_id: fixture-clicked-0001
  created_at: <%= 2.days.ago %>

acme_hard_bounce:
  project: acme_default
  workspace: acme
  source: acme_production
  public_id: em_fixturehardbounce00001
  status: bounced
  bounce_type: permanent
  from: hello@acme.com
  subject: Password reset
  text_body: "Reset link"
  ses_message_id: fixture-hard-bounce-0001
  created_at: <%= 4.days.ago %>

acme_soft_bounce:
  project: acme_default
  workspace: acme
  source: acme_production
  public_id: em_fixturesoftbounce00001
  status: bounced
  bounce_type: transient
  from: hello@acme.com
  subject: Mailbox full retry
  text_body: "Please read"
  ses_message_id: fixture-soft-bounce-0001
  created_at: <%= 5.hours.ago %>

acme_complained:
  project: acme_default
  workspace: acme
  source: acme_production
  public_id: em_fixturecomplained00001
  status: complained
  from: hello@acme.com
  subject: Promo blast
  html_body: "<p>Deals</p>"
  ses_message_id: fixture-complained-0001
  created_at: <%= 10.days.ago %>

acme_failed:
  project: acme_default
  workspace: acme
  source: acme_production
  public_id: em_fixturefailed00000001
  status: failed
  failure_reason: SES rejected the message
  from: hello@acme.com
  subject: Never left
  text_body: "Oops"
  created_at: <%= 6.days.ago %>

acme_ancient:
  project: acme_default
  workspace: acme
  source: acme_production
  public_id: em_fixtureancient0000001
  status: delivered
  from: hello@acme.com
  subject: Old news
  text_body: "Ancient"
  ses_message_id: fixture-ancient-0001
  created_at: <%= 40.days.ago %>

globex_delivered:
  project: globex_default
  workspace: globex
  source: globex_production
  public_id: em_fixtureglobex00000001
  status: delivered
  from: hi@globex.com
  subject: Globex says hi
  text_body: "Hi"
  ses_message_id: fixture-globex-0001
  created_at: <%= 1.hour.ago %>
```

Create `test/fixtures/email_recipients.yml`:

```yaml
acme_welcome_to:
  email: acme_welcome
  kind: to
  address: newuser@example.com

acme_sent_to:
  email: acme_sent
  kind: to
  address: billing@customer.example

acme_delivered_to:
  email: acme_delivered
  kind: to
  address: searchme@customer.example

acme_hard_bounce_to:
  email: acme_hard_bounce
  kind: to
  address: hard@customer.example

acme_soft_bounce_to:
  email: acme_soft_bounce
  kind: to
  address: soft@customer.example

globex_delivered_to:
  email: globex_delivered
  kind: to
  address: someone@globex.example
```

Create `test/fixtures/email_events.yml`:

```yaml
acme_delivered_delivery:
  email: acme_delivered
  event_type: delivery
  recipient: searchme@customer.example
  ses_message_id: fixture-delivered-0001
  occurred_at: <%= 3.hours.ago %>

acme_opened_delivery:
  email: acme_opened
  event_type: delivery
  ses_message_id: fixture-opened-0001
  occurred_at: <%= 2.days.ago %>

acme_opened_open:
  email: acme_opened
  event_type: open
  user_agent: Mozilla/5.0
  ip: 192.0.2.1
  ses_message_id: fixture-opened-0001
  occurred_at: <%= 47.hours.ago %>

acme_clicked_click:
  email: acme_clicked
  event_type: click
  url: https://acme.com
  ses_message_id: fixture-clicked-0001
  occurred_at: <%= 2.days.ago %>

acme_hard_bounce_bounce:
  email: acme_hard_bounce
  event_type: bounce
  recipient: hard@customer.example
  ses_message_id: fixture-hard-bounce-0001
  payload: { bounce: { bounceType: Permanent } }
  occurred_at: <%= 4.days.ago %>

acme_complained_complaint:
  email: acme_complained
  event_type: complaint
  ses_message_id: fixture-complained-0001
  occurred_at: <%= 10.days.ago %>

globex_delivered_delivery:
  email: globex_delivered
  event_type: delivery
  ses_message_id: fixture-globex-0001
  occurred_at: <%= 1.hour.ago %>
```

- [ ] **Step 6: Run the FULL suite — fixture expansion can surface absolute-count assumptions**

Run: `bin/rails test`
Expected: PASS. If a pre-existing test fails on counts, it should be using `wipe_send_domain` (test_helper) — add the wipe to that test's setup rather than shrinking fixtures.

- [ ] **Step 7: Rubocop + commit**

```bash
bin/rubocop
git add -A && git commit -m "feat: emails.bounce_type recorded at SNS ingestion; dashboard fixture set"
```

---

### Task 3: Email filter scopes

**Files:**
- Modify: `app/models/email.rb`
- Test: `test/models/email_test.rb`

**Interfaces:**
- Consumes: the `status` enum from `Email::Statuses` — the enum **already defines** `Email.queued/sent/delivered/opened/clicked/bounced/complained/failed` scopes. Do NOT redefine any of those names; `indexed_by` maps UI params onto them.
- Produces (used by Tasks 4–9): `Email.indexed_by(param)`, `sorted_by(param)`, `in_time_range(param)` (`"1h"/"24h"/"7d"/"30d"`, anything else → `all`), `search(q)`, `preloaded`, `chronologically`, `reverse_chronologically`, `hard_bounced`, `soft_bounced`.

- [ ] **Step 1: Write the failing tests** — append to `test/models/email_test.rb`:

```ruby
test "indexed_by maps UI params onto status scopes" do
  scope = projects(:acme_default).emails

  assert_includes scope.indexed_by("delivered"), emails(:acme_delivered)
  assert_not_includes scope.indexed_by("delivered"), emails(:acme_opened)
  assert_includes scope.indexed_by("bounced"), emails(:acme_hard_bounce)
  assert_includes scope.indexed_by("bounced"), emails(:acme_soft_bounce)
  assert_includes scope.indexed_by("complained"), emails(:acme_complained)
  assert_includes scope.indexed_by("failed"), emails(:acme_failed)
  assert_includes scope.indexed_by("everything-else"), emails(:acme_welcome)
end

test "hard and soft bounce scopes split on bounce_type and exclude unclassified" do
  unclassified = emails(:acme_complained)
  unclassified.update_columns(status: "bounced", bounce_type: nil)

  assert_equal [ emails(:acme_hard_bounce) ], projects(:acme_default).emails.hard_bounced.to_a
  assert_equal [ emails(:acme_soft_bounce) ], projects(:acme_default).emails.soft_bounced.to_a
end

test "in_time_range windows on created_at and passes unknown params through" do
  scope = projects(:acme_default).emails

  assert_includes scope.in_time_range("1h"), emails(:acme_sent)
  assert_not_includes scope.in_time_range("1h"), emails(:acme_delivered)
  assert_includes scope.in_time_range("24h"), emails(:acme_delivered)
  assert_not_includes scope.in_time_range("7d"), emails(:acme_complained)
  assert_includes scope.in_time_range("30d"), emails(:acme_complained)
  assert_not_includes scope.in_time_range("30d"), emails(:acme_ancient)
  assert_includes scope.in_time_range(nil), emails(:acme_ancient)
end

test "sorted_by orders oldest or newest first" do
  scope = projects(:acme_default).emails

  assert_equal scope.order(created_at: :asc, id: :asc).first, scope.sorted_by("oldest").first
  assert_equal scope.order(created_at: :desc, id: :desc).first, scope.sorted_by("whatever").first
end

test "search matches subject, from, public_id and recipient address" do
  scope = projects(:acme_default).emails

  assert_includes scope.search("invoice"), emails(:acme_sent)
  assert_includes scope.search("em_fixturedelivered000001"), emails(:acme_delivered)
  assert_includes scope.search("hello@acme.com"), emails(:acme_sent)
  assert_includes scope.search("searchme@customer"), emails(:acme_delivered)
  assert_not_includes scope.search("searchme@customer"), emails(:acme_sent)
  assert_equal scope.count, scope.search("").count
end

test "search treats LIKE metacharacters literally" do
  assert_empty projects(:acme_default).emails.search("100%")
end

test "preloaded eager-loads the associations the feed renders" do
  email = Email.preloaded.find(emails(:acme_delivered).id)

  assert email.recipients.loaded?
  assert email.events.loaded?
  assert email.association(:source).loaded?
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/models/email_test.rb`
Expected: FAIL — `indexed_by` undefined.

- [ ] **Step 3: Implement** — in `app/models/email.rb`, after the associations:

```ruby
  scope :hard_bounced, -> { bounced.where(bounce_type: "permanent") }
  scope :soft_bounced, -> { bounced.where(bounce_type: "transient") }

  scope :chronologically,         -> { order(created_at: :asc,  id: :asc)  }
  scope :reverse_chronologically, -> { order(created_at: :desc, id: :desc) }

  scope :indexed_by, ->(index) do
    case index
    when "queued"       then queued
    when "sending"      then sending
    when "sent"         then sent
    when "delivered"    then delivered
    when "opened"       then opened
    when "clicked"      then clicked
    when "bounced"      then bounced
    when "hard_bounces" then hard_bounced
    when "soft_bounces" then soft_bounced
    when "complained"   then complained
    when "failed"       then failed
    else all
    end
  end

  scope :sorted_by, ->(sort) do
    case sort
    when "oldest" then chronologically
    else reverse_chronologically
    end
  end

  TIME_RANGES = { "1h" => 1.hour, "24h" => 24.hours, "7d" => 7.days, "30d" => 30.days }.freeze

  scope :in_time_range, ->(param) do
    if window = TIME_RANGES[param]
      where(created_at: window.ago..)
    else
      all
    end
  end

  scope :search, ->(query) do
    if query.present?
      like = "%#{sanitize_sql_like(query)}%"
      where(<<~SQL, q: like).or(where(id: EmailRecipient.where("address LIKE :q", q: like).select(:email_id)))
        subject LIKE :q OR public_id LIKE :q OR "from" LIKE :q
      SQL
    else
      all
    end
  end

  scope :preloaded, -> { preload(:recipients, :events, :source) }
```

(Place `TIME_RANGES` above the scopes if rubocop prefers constants first; keep declaration before use.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/models/email_test.rb`
Expected: PASS.

- [ ] **Step 5: Full suite + rubocop + commit**

```bash
bin/rails test && bin/rubocop
git add -A && git commit -m "feat: email filter scopes — indexed_by, sorted_by, in_time_range, search, preloaded"
```

---

### Task 4: `Project::Metrics` presenter + dashboard tiles + nav

**Prelude:** read patterns §3.4 (presenters) and **the `dataviz` skill** before writing the tile/sparkline markup. This task creates the first `modules`-layer CSS and the shared `auto-submit` Stimulus controller.

**Files:**
- Create: `app/models/project/metrics.rb`
- Modify: `app/models/project.rb` (factory), `app/controllers/dashboards_controller.rb`, `app/views/dashboards/show.html.erb`, `app/views/layouts/application.html.erb`
- Create: `app/views/layouts/_nav.html.erb`, `app/views/dashboards/_tile.html.erb`
- Create: `app/javascript/controllers/auto_submit_controller.js`
- Create: `app/assets/stylesheets/nav.css`, `app/assets/stylesheets/metrics.css`
- Test: Create `test/models/project/metrics_test.rb`; modify `test/controllers/dashboards_controller_test.rb`

**Interfaces:**
- Consumes: `emails.created_at`, `email_events.event_type/occurred_at`, `Rails.cache` (memory store in test — assert values, not store internals).
- Produces: `project.metrics_for(range_param)` → `Project::Metrics` with `range`, `sent_count`, `delivered_count`, `opened_count`, `clicked_count`, `bounced_count`, `complaint_count`, `delivery_rate`, `open_rate`, `click_rate`, `bounce_rate` (floats, % rounded to 1 decimal, 0.0 on zero denominator), `sent_delta`, `delivery_rate_delta`, `open_rate_delta`, `click_rate_delta`, `bounce_rate_delta`, `complaint_delta`, `sparkline_values` (zero-filled Integer array: 24 hourly buckets for `"24h"`, 7/30 daily), `sparkline_points(width:, height:)` (SVG polyline points string), `cache_key`.
- Counting semantics (documented decision): funnel counts come from `email_events` (distinct `email_id` per event type in the window) because `status` is monotonic and error states don't imply delivery; the volume denominator is accepted emails (`created_at` in window). `open_rate`/`click_rate` are over delivered; `delivery_rate`/`bounce_rate` over accepted.

- [ ] **Step 1: Write the failing model test** — create `test/models/project/metrics_test.rb`:

```ruby
require "test_helper"

class Project::MetricsTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    @project = projects(:acme_default)
    wipe_send_domain
    Rails.cache.clear # cache keys include max(updated_at) at 1s resolution — two tests creating rows in the same second would otherwise share entries
  end

  test "counts volume from emails and the funnel from distinct event emails" do
    delivered = create_email(created_at: 1.hour.ago)
    opened = create_email(created_at: 2.hours.ago)
    create_email(created_at: 3.hours.ago) # accepted, no events
    record_event(delivered, "delivery", 1.hour.ago)
    record_event(opened, "delivery", 2.hours.ago)
    record_event(opened, "open", 1.hour.ago)
    record_event(opened, "open", 30.minutes.ago) # duplicate open, same email

    metrics = @project.metrics_for("24h")

    assert_equal 3, metrics.sent_count
    assert_equal 2, metrics.delivered_count
    assert_equal 1, metrics.opened_count
    assert_in_delta 66.7, metrics.delivery_rate
    assert_in_delta 50.0, metrics.open_rate
  end

  test "rates guard divide-by-zero" do
    metrics = @project.metrics_for("24h")

    assert_equal 0, metrics.sent_count
    assert_equal 0.0, metrics.delivery_rate
    assert_equal 0.0, metrics.open_rate
  end

  test "deltas compare against the immediately preceding window of equal length" do
    create_email(created_at: 2.hours.ago)
    create_email(created_at: 3.hours.ago)
    create_email(created_at: 30.hours.ago) # previous 24h window

    metrics = @project.metrics_for("24h")

    assert_equal 1, metrics.sent_delta
  end

  test "sparkline zero-fills one bucket per interval" do
    create_email(created_at: 1.hour.ago)

    assert_equal 24, @project.metrics_for("24h").sparkline_values.size
    assert_equal 7, @project.metrics_for("7d").sparkline_values.size
    assert_equal 30, @project.metrics_for("30d").sparkline_values.size
    assert_equal 1, @project.metrics_for("24h").sparkline_values.sum
  end

  test "unknown ranges fall back to 7d" do
    assert_equal "7d", @project.metrics_for("century").range
    assert_equal "7d", @project.metrics_for(nil).range
  end

  test "cache_key changes when email activity lands" do
    before = @project.metrics_for("7d").cache_key
    create_email(created_at: 5.minutes.ago)

    assert_not_equal before, @project.metrics_for("7d").cache_key
  end

  private
    def create_email(created_at:)
      @project.emails.create!(source: sources(:acme_production), from: "hello@acme.com",
        subject: "Metric", text_body: "Body", created_at: created_at)
    end

    def record_event(email, event_type, occurred_at)
      email.events.create!(event_type: event_type, occurred_at: occurred_at)
    end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/models/project/metrics_test.rb`
Expected: FAIL — `Project::Metrics` not defined / `metrics_for` missing.

- [ ] **Step 3: Implement the presenter** — create `app/models/project/metrics.rb`:

```ruby
class Project::Metrics
  RANGES = { "24h" => 24.hours, "7d" => 7.days, "30d" => 30.days }.freeze
  DEFAULT_RANGE = "7d"
  EVENT_COUNTERS = { delivered: "delivery", opened: "open", clicked: "click",
    bounced: "bounce", complained: "complaint" }.freeze

  attr_reader :project, :range

  def initialize(project, range: DEFAULT_RANGE)
    @project = project
    @range = RANGES.key?(range.to_s) ? range.to_s : DEFAULT_RANGE
  end

  def sent_count
    current.fetch(:accepted)
  end

  def delivered_count
    current.fetch(:delivered)
  end

  def opened_count
    current.fetch(:opened)
  end

  def clicked_count
    current.fetch(:clicked)
  end

  def bounced_count
    current.fetch(:bounced)
  end

  def complaint_count
    current.fetch(:complained)
  end

  def delivery_rate
    rate(current[:delivered], current[:accepted])
  end

  def open_rate
    rate(current[:opened], current[:delivered])
  end

  def click_rate
    rate(current[:clicked], current[:delivered])
  end

  def bounce_rate
    rate(current[:bounced], current[:accepted])
  end

  def sent_delta
    current[:accepted] - previous[:accepted]
  end

  def delivery_rate_delta
    delivery_rate - rate(previous[:delivered], previous[:accepted])
  end

  def open_rate_delta
    open_rate - rate(previous[:opened], previous[:delivered])
  end

  def click_rate_delta
    click_rate - rate(previous[:clicked], previous[:delivered])
  end

  def bounce_rate_delta
    bounce_rate - rate(previous[:bounced], previous[:accepted])
  end

  def complaint_delta
    current[:complained] - previous[:complained]
  end

  def sparkline_values
    computed.fetch(:sparkline)
  end

  def sparkline_points(width: 120, height: 32)
    values = sparkline_values
    peak = [ values.max.to_i, 1 ].max
    step = width.to_f / [ values.size - 1, 1 ].max

    values.each_with_index.map do |value, index|
      "#{(index * step).round(1)},#{(height - (value * height.to_f / peak)).round(1)}"
    end.join(" ")
  end

  def cache_key
    [ "project-metrics", project.id, range, project.emails.maximum(:updated_at)&.to_i ].join("/")
  end

  private
    def current
      computed.fetch(:current)
    end

    def previous
      computed.fetch(:previous)
    end

    def computed
      @computed ||= Rails.cache.fetch(cache_key, expires_in: 60.seconds) do
        { current: totals_in(current_period), previous: totals_in(previous_period),
          sparkline: zero_filled_buckets }
      end
    end

    def current_period
      window.ago..Time.current
    end

    def previous_period
      (window * 2).ago..window.ago
    end

    def window
      RANGES.fetch(range)
    end

    def totals_in(period)
      event_counts = EmailEvent.where(email_id: project.emails.select(:id), occurred_at: period)
        .group(:event_type).distinct.count(:email_id)

      EVENT_COUNTERS.transform_values { |event_type| event_counts.fetch(event_type, 0) }
        .merge(accepted: project.emails.where(created_at: period).count)
    end

    def zero_filled_buckets
      counts = project.emails.where(created_at: current_period)
        .group(Arel.sql("strftime('#{bucket_format}', created_at)")).count

      bucket_labels.map { |label| counts.fetch(label, 0) }
    end

    def bucket_format
      range == "24h" ? "%Y-%m-%dT%H" : "%Y-%m-%d"
    end

    # created_at is stored UTC, so bucket labels are computed in UTC to match
    # what SQLite's strftime sees.
    def bucket_labels
      step = range == "24h" ? 1.hour : 1.day
      count = (window / step).to_i
      newest = range == "24h" ? Time.current.utc.beginning_of_hour : Time.current.utc.beginning_of_day

      (0...count).map { |index| (newest - (count - 1 - index) * step).strftime(bucket_format) }
    end

    def rate(numerator, denominator)
      if denominator.zero?
        0.0
      else
        (numerator * 100.0 / denominator).round(1)
      end
    end
end
```

Add the factory to `app/models/project.rb` (public methods, after `deletable?`):

```ruby
  def metrics_for(range)
    Project::Metrics.new(self, range: range.to_s)
  end
```

- [ ] **Step 4: Run the model tests**

Run: `bin/rails test test/models/project/metrics_test.rb`
Expected: PASS. (Note: memory-store caching within one test could serve stale totals across `metrics_for` calls — `cache_key` embeds `maximum(:updated_at)`, so new rows bust it. If a test creates data and re-reads within the same second, use distinct `created_at`s as the tests above do.)

- [ ] **Step 5: Controller + views + nav + Stimulus + CSS**

`app/controllers/dashboards_controller.rb`:

```ruby
class DashboardsController < ApplicationController
  def show
    if Current.project
      @metrics = Current.project.metrics_for(params[:range])
    end
  end
end
```

`app/javascript/controllers/auto_submit_controller.js` (shared by the range picker now and the activity/email filters later):

```javascript
import { Controller } from "@hotwired/stimulus"

// Submits the surrounding form whenever a control changes.
export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }
}
```

`app/views/layouts/_nav.html.erb` (links for later sections are added by their tasks):

```erb
<nav class="nav" aria-label="Primary">
  <%= link_to "Dashboard", root_path, class: "nav__link", aria: { current: current_page?(root_path) ? "page" : nil } %>
</nav>
```

In `app/views/layouts/application.html.erb`, render it inside the authenticated header, after the logo link:

```erb
      <header class="flex align-center justify-space-between pad">
        <div class="flex align-center gap">
          <%= link_to "Departures", root_path, class: "font-weight-bold txt-medium" %>
          <%= render "layouts/nav" %>
        </div>
        <%= render "workspaces/switcher" %>
        <%= button_to "Sign out", session_path, method: :delete, class: "btn btn--plain btn--medium" %>
      </header>
```

`app/views/dashboards/show.html.erb` — **keep the `data-workspace-slug`/`data-project-slug` wrapper**: an existing test in `dashboards_controller_test.rb` asserts on it:

```erb
<div data-workspace-slug="<%= Current.workspace&.slug %>" data-project-slug="<%= Current.project&.slug %>">
<% if Current.project %>
  <div class="flex align-center justify-space-between margin-block">
    <h1 class="margin-none txt-large"><%= Current.project.name %> overview</h1>
    <%= form_with url: root_path, method: :get, data: { controller: "auto-submit" } do |form| %>
      <%= form.select :range,
            options_for_select({ "Last 24 hours" => "24h", "Last 7 days" => "7d", "Last 30 days" => "30d" }, @metrics.range),
            {}, class: "input input--select", aria: { label: "Time range" },
            data: { action: "change->auto-submit#submit" } %>
    <% end %>
  </div>

  <% cache @metrics.cache_key do %>
    <div class="metrics">
      <%= render "tile", label: "Sent", value: @metrics.sent_count, delta: @metrics.sent_delta, suffix: "", up_is_good: true %>
      <%= render "tile", label: "Delivery rate", value: @metrics.delivery_rate, delta: @metrics.delivery_rate_delta, suffix: "%", up_is_good: true %>
      <%= render "tile", label: "Open rate", value: @metrics.open_rate, delta: @metrics.open_rate_delta, suffix: "%", up_is_good: true %>
      <%= render "tile", label: "Click rate", value: @metrics.click_rate, delta: @metrics.click_rate_delta, suffix: "%", up_is_good: true %>
      <%= render "tile", label: "Bounce rate", value: @metrics.bounce_rate, delta: @metrics.bounce_rate_delta, suffix: "%", up_is_good: false %>
      <%= render "tile", label: "Complaints", value: @metrics.complaint_count, delta: @metrics.complaint_delta, suffix: "", up_is_good: false %>
    </div>

    <figure class="sparkline margin-block" aria-label="Emails sent per <%= @metrics.range == "24h" ? "hour" : "day" %>">
      <svg viewBox="0 0 120 32" preserveAspectRatio="none" role="img">
        <polyline points="<%= @metrics.sparkline_points %>" fill="none" stroke="currentColor" stroke-width="1.5" vector-effect="non-scaling-stroke" />
      </svg>
      <figcaption class="txt-x-small txt-subtle">Send volume, <%= { "24h" => "last 24 hours", "7d" => "last 7 days", "30d" => "last 30 days" }[@metrics.range] %></figcaption>
    </figure>
  <% end %>
<% else %>
  <p class="txt-subtle margin-block">No active project yet — create a project to start sending.</p>
<% end %>
</div>
```

`app/views/dashboards/_tile.html.erb`:

```erb
<div class="metric-tile">
  <p class="metric-tile__label"><%= label %></p>
  <p class="metric-tile__value"><%= value %><%= suffix %></p>
  <% direction = delta >= 0 ? "up" : "down" %>
  <% tone = (delta >= 0) == up_is_good ? "good" : "bad" %>
  <p class="metric-tile__delta metric-tile__delta--<%= delta.zero? ? "flat" : tone %>">
    <%= direction == "up" ? "▲" : "▼" unless delta.zero? %>
    <%= delta.abs.round(1) %><%= suffix %> vs prior period
  </p>
</div>
```

`app/assets/stylesheets/nav.css`:

```css
@layer modules {
  .nav {
    display: flex;
    gap: var(--inline-space);
  }

  .nav__link {
    border-radius: 0.5em;
    color: var(--color-ink-light);
    padding: 0.35em 0.8em;
    text-decoration: none;

    &:hover {
      color: var(--color-ink);
    }

    &[aria-current="page"] {
      background-color: var(--color-surface);
      color: var(--color-ink);
      font-weight: 700;
    }
  }
}
```

`app/assets/stylesheets/metrics.css`:

```css
@layer modules {
  .metrics {
    display: grid;
    gap: var(--block-space);
    grid-template-columns: repeat(auto-fit, minmax(11rem, 1fr));
  }

  .metric-tile {
    background-color: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 0.75em;
    padding: var(--block-space) var(--inline-space-double, 2ch);
  }

  .metric-tile__label {
    color: var(--color-ink-lighter);
    font-size: var(--text-x-small);
    letter-spacing: 0.04em;
    margin: 0;
    text-transform: uppercase;
  }

  .metric-tile__value {
    font-size: var(--text-large);
    font-variant-numeric: tabular-nums;
    font-weight: 700;
    margin-block: var(--block-space-half) 0;
  }

  .metric-tile__delta {
    font-size: var(--text-x-small);
    margin-block: var(--block-space-half) 0;

    &.metric-tile__delta--good { color: var(--color-positive); }
    &.metric-tile__delta--bad  { color: var(--color-negative); }
    &.metric-tile__delta--flat { color: var(--color-ink-lighter); }
  }

  .sparkline {
    color: var(--color-link);
    margin-inline: 0;

    svg {
      block-size: 4rem;
      display: block;
      inline-size: 100%;
    }
  }
}
```

- [ ] **Step 6: Controller test** — append to `test/controllers/dashboards_controller_test.rb`:

```ruby
test "shows metric tiles for the current project" do
  sign_in_as users(:owner)
  get root_url

  assert_response :success
  assert_select ".metric-tile", 6
  assert_select ".sparkline svg polyline"
end

test "range param drives the metrics window" do
  sign_in_as users(:owner)
  get root_url(range: "24h")

  assert_response :success
  assert_select "option[value=?][selected]", "24h"
end
```

- [ ] **Step 7: Run, verify, commit**

```bash
bin/rails test test/models/project/metrics_test.rb test/controllers/dashboards_controller_test.rb
bin/rails test && bin/rubocop
git add -A && git commit -m "feat: Project::Metrics presenter, dashboard tiles + sparkline, primary nav"
```

Manual check (fast): `bin/dev`, load `/`, toggle OS dark mode — tiles/nav must hold up in both themes.

---

### Task 5: Activity feed (live)

**Files:**
- Modify: `config/routes.rb`, `app/views/layouts/application.html.erb` (head + nav link)
- Create: `app/controllers/activity_controller.rb`, `app/views/activity/show.html.erb`, `app/views/activity/_email.html.erb`, `app/views/emails/_status_pill.html.erb`
- Create: `app/assets/stylesheets/status_pill.css` (components layer), `app/assets/stylesheets/activity.css` (modules layer)
- Test: Create `test/controllers/activity_controller_test.rb`

**Interfaces:**
- Consumes: Task 3 scopes; `Broadcastable` already broadcasts `broadcast_refresh_to(project, :activity)` after every status advance — the page only has to subscribe and be morph-idempotent.
- Produces: `GET /activity` (`activity_path`); `emails/_status_pill` partial (reused by Tasks 6 and 8); the layout gains `turbo_refreshes_with method: :morph, scroll: :preserve`.

- [ ] **Step 1: Write the failing controller test** — create `test/controllers/activity_controller_test.rb`:

```ruby
require "test_helper"

class ActivityControllerTest < ActionDispatch::IntegrationTest
  test "requires authentication" do
    get activity_url

    assert_redirected_to new_session_url
  end

  test "lists the current project's latest emails with a live stream subscription" do
    sign_in_as users(:owner)
    get activity_url

    assert_response :success
    assert_select "turbo-cable-stream-source", 1
    assert_select ".activity__row", { minimum: 5 }
    assert_select "body", text: /April invoice/
    assert_select "body", { text: /Globex says hi/, count: 0 }
  end

  test "filter and range params narrow the feed" do
    sign_in_as users(:owner)
    get activity_url(filter: "bounced")

    assert_select "body", text: /Password reset/
    assert_select "body", { text: /April invoice/, count: 0 }

    get activity_url(range: "1h")

    assert_select "body", text: /April invoice/
    assert_select "body", { text: /Welcome aboard/, count: 0 }
  end

  test "search narrows by recipient" do
    sign_in_as users(:owner)
    get activity_url(q: "searchme@customer")

    assert_select "body", text: /Welcome aboard/
    assert_select "body", { text: /April invoice/, count: 0 }
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/controllers/activity_controller_test.rb`
Expected: FAIL — no route matches `activity_url`.

- [ ] **Step 3: Implement**

`config/routes.rb` — add after the invitation acceptance block:

```ruby
  resource :activity, only: :show, controller: "activity"
```

`app/controllers/activity_controller.rb`:

```ruby
class ActivityController < ApplicationController
  def show
    if Current.project
      @emails = Current.project.emails.indexed_by(params[:filter]).in_time_range(params[:range])
        .search(params[:q]).reverse_chronologically.preloaded.limit(50)
    end
  end
end
```

Layout head — enable morphing page refreshes (required for the refresh broadcast to feel live rather than jumpy). In `application.html.erb` `<head>`, after `csp_meta_tag`:

```erb
    <%= turbo_refreshes_with method: :morph, scroll: :preserve %>
```

Nav link in `app/views/layouts/_nav.html.erb` (after Dashboard):

```erb
  <%= link_to "Activity", activity_path, class: "nav__link", aria: { current: current_page?(activity_path) ? "page" : nil } %>
```

`app/views/activity/show.html.erb`:

```erb
<% if Current.project %>
  <%= turbo_stream_from Current.project, :activity %>

  <div class="flex align-center justify-space-between margin-block">
    <h1 class="margin-none txt-large">Activity</h1>
    <%= form_with url: activity_path, method: :get, data: { controller: "auto-submit" }, class: "flex align-center gap-half" do |form| %>
      <label class="flex align-center gap-half input input--actor">
        <%= icon_tag "search" %>
        <%= form.search_field :q, value: params[:q], placeholder: "Search subject, address, id…", class: "input" %>
      </label>
      <%= form.select :filter,
            options_for_select({ "All statuses" => "", "Queued" => "queued", "Sent" => "sent", "Delivered" => "delivered",
              "Opened" => "opened", "Clicked" => "clicked", "Bounced" => "bounced", "Complained" => "complained",
              "Failed" => "failed" }, params[:filter]),
            {}, class: "input input--select", aria: { label: "Status filter" }, data: { action: "change->auto-submit#submit" } %>
      <%= form.select :range,
            options_for_select({ "All time" => "", "Last hour" => "1h", "Last 24 hours" => "24h",
              "Last 7 days" => "7d", "Last 30 days" => "30d" }, params[:range]),
            {}, class: "input input--select", aria: { label: "Time range" }, data: { action: "change->auto-submit#submit" } %>
      <button type="submit" class="btn btn--secondary btn--medium">Search</button>
    <% end %>
  </div>

  <div class="activity" id="activity_feed">
    <% if @emails.any? %>
      <%= render partial: "activity/email", collection: @emails %>
    <% else %>
      <p class="txt-subtle pad-block">Nothing here yet — matching emails will appear live as they move.</p>
    <% end %>
  </div>
<% else %>
  <p class="txt-subtle margin-block">No active project yet.</p>
<% end %>
```

`app/views/activity/_email.html.erb`:

```erb
<div class="activity__row" id="<%= dom_id(email) %>">
  <%= render "emails/status_pill", email: email %>
  <div class="activity__summary">
    <p class="margin-none font-weight-bold"><%= email.subject %></p>
    <p class="margin-none txt-small txt-subtle">
      <%= email.from %> → <%= email.recipients.filter { |recipient| recipient.kind_to? }.map(&:address).join(", ") %>
    </p>
  </div>
  <p class="margin-none txt-x-small txt-subtle activity__time">
    <%= time_ago_in_words(email.created_at) %> ago
  </p>
</div>
```

(Recipients are preloaded — filter in Ruby, don't re-query.)

`app/views/emails/_status_pill.html.erb`:

```erb
<span class="status-pill status-pill--<%= email.status %>"><%= email.status %></span>
```

`app/assets/stylesheets/status_pill.css`:

```css
@layer components {
  .status-pill {
    background-color: color-mix(in oklch, var(--pill-color, var(--color-ink-lighter)) 15%, var(--color-surface));
    border-radius: 2em;
    color: var(--pill-color, var(--color-ink-light));
    display: inline-block;
    font-size: var(--text-x-small);
    font-weight: 700;
    padding: 0.15em 0.9em;
    text-transform: capitalize;

    &.status-pill--sent,
    &.status-pill--delivered { --pill-color: var(--color-positive); }

    &.status-pill--opened,
    &.status-pill--clicked { --pill-color: var(--color-link); }

    &.status-pill--bounced,
    &.status-pill--failed,
    &.status-pill--complained { --pill-color: var(--color-negative); }
  }
}
```

`app/assets/stylesheets/activity.css`:

```css
@layer modules {
  .activity {
    background-color: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 0.75em;
  }

  .activity__row {
    align-items: center;
    display: flex;
    gap: var(--inline-space);
    padding: var(--block-space-half) var(--inline-space);

    & + .activity__row {
      border-block-start: 1px solid var(--color-border);
    }
  }

  .activity__summary {
    flex: 1;
    min-inline-size: 0;
  }

  .activity__time {
    white-space: nowrap;
  }
}
```

- [ ] **Step 4: Run tests**

Run: `bin/rails test test/controllers/activity_controller_test.rb`
Expected: PASS.

- [ ] **Step 5: Full suite + rubocop + commit**

```bash
bin/rails test && bin/rubocop
git add -A && git commit -m "feat: live activity feed — filters, search, [project, :activity] subscription"
```

Manual check: `bin/dev`, open `/activity` in two windows; from `bin/rails console` run `Email.last.mark_sending` — both windows must morph-refresh.

---

### Task 6: Emails index + inspector (show / preview / raw)

**Files:**
- Modify: `config/routes.rb`, `app/models/email.rb` (`to_param`), `app/views/layouts/_nav.html.erb`
- Create: `app/controllers/concerns/email_scoped.rb`, `app/controllers/emails_controller.rb`
- Create: `app/views/emails/index.html.erb`, `app/views/emails/_email.html.erb`, `app/views/emails/show.html.erb`
- Create: `app/javascript/controllers/drawer_controller.js`, `app/javascript/controllers/clipboard_controller.js`
- Create: `app/assets/stylesheets/emails.css`
- Test: Create `test/controllers/emails_controller_test.rb`

**Interfaces:**
- Consumes: Task 3 scopes, `Email::MimeStore.root`, `emails/_status_pill`, `auto-submit` Stimulus.
- Produces: `Email#to_param` → `public_id` (so `email_path(email)` builds public-id URLs everywhere); `EmailScoped` concern (`@email` from `Current.project.emails.find_by!(public_id: params[:email_id] || params[:id])`, 404 on cross-tenant/missing project) — Task 7's resends controller includes it; routes `resources :emails, only: %i[index show]` + member GETs `preview`/`raw`.

- [ ] **Step 1: Write the failing tests** — create `test/controllers/emails_controller_test.rb`:

```ruby
require "test_helper"

class EmailsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
  end

  test "index lists and filters the current project's emails" do
    get emails_url

    assert_response :success
    assert_select "body", text: /April invoice/
    assert_select "body", { text: /Globex says hi/, count: 0 }

    get emails_url(filter: "failed")

    assert_select "body", text: /Never left/
    assert_select "body", { text: /April invoice/, count: 0 }
  end

  test "show renders the inspector by public_id" do
    get email_url(emails(:acme_delivered))

    assert_response :success
    assert_select "body", text: /Welcome aboard/
    assert_select "body", text: /searchme@customer.example/
  end

  test "cross-tenant emails 404" do
    get email_url(emails(:globex_delivered))

    assert_response :not_found
  end

  test "preview renders the html body under a strict CSP" do
    get preview_email_url(emails(:acme_delivered))

    assert_response :success
    assert_includes response.body, "<p>Hi!</p>"
    assert_equal "default-src 'none'; img-src * data:; style-src 'unsafe-inline'",
      response.headers["Content-Security-Policy"]
    assert_equal "SAMEORIGIN", response.headers["X-Frame-Options"]
  end

  test "preview falls back to the text body" do
    get preview_email_url(emails(:acme_sent))

    assert_response :success
    assert_includes response.body, "Invoice attached"
  end

  test "raw sends the archived eml" do
    email = create_stored_email

    get raw_email_url(email)

    assert_response :success
    assert_equal "message/rfc822", response.media_type
    assert_includes response.body, "X-Departures-Id: #{email.public_id}"
  end

  test "raw 404s when the mime was pruned" do
    get raw_email_url(emails(:acme_delivered))

    assert_response :not_found
  end

  private
    def create_stored_email
      EmailSubmission.new(project: projects(:acme_default), source: sources(:acme_production),
        from: "hello@acme.com", to: [ "raw@example.com" ], subject: "Raw me", text: "Body").save
    end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/controllers/emails_controller_test.rb`
Expected: FAIL — no `emails_url` route.

- [ ] **Step 3: Implement**

`config/routes.rb` — after the activity route:

```ruby
  resources :emails, only: %i[ index show ] do
    member do
      get :preview
      get :raw
    end
    scope module: :emails do
      resource :resend, only: :create
    end
  end
```

(The resend route ships now; its controller lands in Task 7 — nothing links to it yet.)

`app/models/email.rb` — public method (public IDs are the only ids the dashboard exposes):

```ruby
  def to_param
    public_id
  end
```

`app/controllers/concerns/email_scoped.rb`:

```ruby
module EmailScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_email
  end

  private
    def set_email
      if Current.project
        @email = Current.project.emails.find_by!(public_id: params[:email_id] || params[:id])
      else
        raise ActiveRecord::RecordNotFound
      end
    end
end
```

`app/controllers/emails_controller.rb`:

```ruby
class EmailsController < ApplicationController
  PREVIEW_CSP = "default-src 'none'; img-src * data:; style-src 'unsafe-inline'".freeze

  include EmailScoped
  skip_before_action :set_email, only: :index

  def index
    if Current.project
      @emails = Current.project.emails.indexed_by(params[:filter]).sorted_by(params[:sort])
        .in_time_range(params[:range]).search(params[:q]).preloaded.limit(100)
    end
  end

  def show
  end

  # Customer HTML renders inside a sandboxed iframe: scripts/frames/fetches are
  # blocked by the CSP; remote + data images and inline styles stay allowed
  # because marketing mail depends on them.
  def preview
    response.headers["Content-Security-Policy"] = PREVIEW_CSP
    response.headers["X-Frame-Options"] = "SAMEORIGIN"

    if @email.html_body.present?
      render html: @email.html_body.html_safe, layout: false
    else
      render plain: @email.text_body.to_s
    end
  end

  def raw
    if @email.mime_path.present?
      send_file Email::MimeStore.root.join(@email.mime_path), type: "message/rfc822",
        filename: "#{@email.public_id}.eml", disposition: "attachment"
    else
      head :not_found
    end
  end
end
```

`app/javascript/controllers/drawer_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Opens the inspector <dialog> when its turbo-frame loads content.
export default class extends Controller {
  static targets = [ "dialog", "frame" ]

  open() {
    if (!this.dialogTarget.open) this.dialogTarget.showModal()
  }

  close() {
    this.dialogTarget.close()
    this.frameTarget.removeAttribute("src")
    this.frameTarget.innerHTML = ""
  }
}
```

`app/javascript/controllers/clipboard_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { text: String }

  copy() {
    navigator.clipboard.writeText(this.textValue)
  }
}
```

`app/views/emails/index.html.erb`:

```erb
<% if Current.project %>
  <div class="flex align-center justify-space-between margin-block">
    <h1 class="margin-none txt-large">Emails</h1>
    <div class="flex align-center gap-half">
      <%= form_with url: emails_path, method: :get, data: { controller: "auto-submit" }, class: "flex align-center gap-half" do |form| %>
        <label class="flex align-center gap-half input input--actor">
          <%= icon_tag "search" %>
          <%= form.search_field :q, value: params[:q], placeholder: "Search…", class: "input" %>
        </label>
        <%= form.select :filter,
              options_for_select({ "All statuses" => "", "Queued" => "queued", "Sent" => "sent", "Delivered" => "delivered",
                "Opened" => "opened", "Clicked" => "clicked", "Bounced" => "bounced", "Complained" => "complained",
                "Failed" => "failed" }, params[:filter]),
              {}, class: "input input--select", aria: { label: "Status filter" }, data: { action: "change->auto-submit#submit" } %>
        <%= form.select :range,
              options_for_select({ "All time" => "", "Last hour" => "1h", "Last 24 hours" => "24h",
                "Last 7 days" => "7d", "Last 30 days" => "30d" }, params[:range]),
              {}, class: "input input--select", aria: { label: "Time range" }, data: { action: "change->auto-submit#submit" } %>
        <button type="submit" class="btn btn--secondary btn--medium">Search</button>
      <% end %>
    </div>
  </div>

  <div data-controller="drawer">
    <div class="emails-table">
      <% if @emails.any? %>
        <%= render partial: "emails/email", collection: @emails %>
      <% else %>
        <p class="txt-subtle pad">No emails match.</p>
      <% end %>
    </div>

    <dialog class="drawer" data-drawer-target="dialog">
      <button class="btn btn--plain btn--medium drawer__close" data-action="click->drawer#close" aria-label="Close inspector">
        <%= icon_tag "close" %>
      </button>
      <%= turbo_frame_tag "email_inspector", data: { drawer_target: "frame", action: "turbo:frame-load->drawer#open" } %>
    </dialog>
  </div>
<% else %>
  <p class="txt-subtle margin-block">No active project yet.</p>
<% end %>
```

(The "Export CSV" link for this page is added in Task 8, once the exports route exists — the Task 6 view must not reference `export_path`.)

`app/views/emails/_email.html.erb`:

```erb
<div class="emails-table__row">
  <%= render "emails/status_pill", email: email %>
  <%= link_to email_path(email), data: { turbo_frame: "email_inspector" }, class: "emails-table__subject" do %>
    <span class="font-weight-bold"><%= email.subject %></span>
    <span class="txt-small txt-subtle"><%= email.from %> → <%= email.recipients.filter { |recipient| recipient.kind_to? }.map(&:address).join(", ") %></span>
  <% end %>
  <span class="txt-x-small txt-subtle"><%= l email.created_at, format: :short %></span>
</div>
```

`app/views/emails/show.html.erb` (renders inside the inspector frame; the resend button arrives in Task 7):

```erb
<%= turbo_frame_tag "email_inspector" do %>
  <article class="inspector">
    <header class="flex align-center gap margin-block-half">
      <%= render "emails/status_pill", email: @email %>
      <h2 class="margin-none txt-medium"><%= @email.subject %></h2>
    </header>

    <dl class="inspector__meta txt-small">
      <dt>From</dt><dd><%= @email.from %></dd>
      <dt>To</dt><dd><%= @email.recipients.kind_to.pluck(:address).join(", ") %></dd>
      <% if @email.recipients.kind_cc.any? %><dt>Cc</dt><dd><%= @email.recipients.kind_cc.pluck(:address).join(", ") %></dd><% end %>
      <dt>Id</dt>
      <dd class="flex align-center gap-half">
        <code><%= @email.public_id %></code>
        <button class="btn btn--plain btn--medium" data-controller="clipboard" data-clipboard-text-value="<%= @email.public_id %>" data-action="click->clipboard#copy" aria-label="Copy id">
          <%= icon_tag "copy-paste" %>
        </button>
      </dd>
      <% if @email.ses_message_id.present? %><dt>SES id</dt><dd><code><%= @email.ses_message_id %></code></dd><% end %>
      <% if @email.failure_reason.present? %><dt>Failure</dt><dd class="txt-negative"><%= @email.failure_reason %></dd><% end %>
      <% if @email.tags.any? %><dt>Tags</dt><dd><%= @email.tags.map { |name, value| "#{name}=#{value}" }.join(" · ") %></dd><% end %>
    </dl>

    <h3 class="txt-small txt-subtle">Timeline</h3>
    <ol class="inspector__timeline txt-small">
      <% @email.events.reverse_chronologically.each do |event| %>
        <li>
          <span class="font-weight-bold"><%= event.event_type %></span>
          <span class="txt-subtle"><%= l event.occurred_at, format: :short %></span>
          <% if event.recipient.present? %><span class="txt-subtle"><%= event.recipient %></span><% end %>
          <% if event.url.present? %><span class="txt-subtle"><%= event.url %></span><% end %>
        </li>
      <% end %>
    </ol>

    <% if @email.html_body.present? %>
      <h3 class="txt-small txt-subtle">Preview</h3>
      <iframe class="inspector__preview" src="<%= preview_email_path(@email) %>"
        sandbox="allow-same-origin" referrerpolicy="no-referrer" loading="lazy" title="Email preview"></iframe>
    <% end %>

    <footer class="flex align-center gap margin-block">
      <% if @email.mime_path.present? %>
        <%= link_to "Download .eml", raw_email_path(@email), class: "btn btn--plain btn--medium", data: { turbo: false } %>
      <% end %>
    </footer>
  </article>
<% end %>
```

`app/assets/stylesheets/emails.css`:

```css
@layer modules {
  .emails-table {
    background-color: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 0.75em;
  }

  .emails-table__row {
    align-items: center;
    display: flex;
    gap: var(--inline-space);
    padding: var(--block-space-half) var(--inline-space);

    & + .emails-table__row {
      border-block-start: 1px solid var(--color-border);
    }
  }

  .emails-table__subject {
    color: inherit;
    display: flex;
    flex: 1;
    flex-direction: column;
    min-inline-size: 0;
    text-decoration: none;

    &:hover .font-weight-bold {
      text-decoration: underline;
    }
  }

  .drawer {
    background-color: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 0.75em 0 0 0.75em;
    block-size: 100dvh;
    color: var(--color-ink);
    inline-size: min(40rem, 90dvw);
    inset-block: 0;
    inset-inline: auto 0;
    margin: 0;
    max-block-size: none;
    padding: var(--block-space) var(--inline-space);

    &::backdrop {
      background-color: oklch(var(--lch-black) / 40%);
    }
  }

  .drawer__close {
    inset-block-start: var(--block-space-half);
    inset-inline-end: var(--inline-space);
    position: absolute;
  }

  .inspector__meta {
    display: grid;
    gap: var(--block-space-half) var(--inline-space);
    grid-template-columns: auto 1fr;

    dt { color: var(--color-ink-lighter); }
    dd { margin: 0; overflow-wrap: anywhere; }
  }

  .inspector__timeline {
    border-inline-start: 2px solid var(--color-border);
    list-style: none;
    padding-inline-start: var(--inline-space);

    li { padding-block: 0.2em; }
  }

  .inspector__preview {
    background-color: white;
    border: 1px solid var(--color-border);
    border-radius: 0.5em;
    block-size: 24rem;
    inline-size: 100%;
  }
}
```

Nav link in `_nav.html.erb` (after Activity):

```erb
  <%= link_to "Emails", emails_path, class: "nav__link", aria: { current: current_page?(emails_path) ? "page" : nil } %>
```

- [ ] **Step 4: Run tests**

Run: `bin/rails test test/controllers/emails_controller_test.rb`
Expected: PASS. (`raw` test relies on `config.x.mime_store_root` pointing at a tmp dir in `config/environments/test.rb` — Phase 2 set this; verify it's still there if the test can't find the file.)

- [ ] **Step 5: Brakeman check (preview renders stored HTML)**

Run: `bin/brakeman --no-pager -q`
If it flags the `render html: @email.html_body.html_safe`, add the warning fingerprint to `config/brakeman.ignore` with the note: "Intentional: customer MIME preview, isolated by per-response CSP (default-src 'none') + sandboxed iframe; never rendered into the app layout."

- [ ] **Step 6: Full suite + rubocop + commit**

```bash
bin/rails test && bin/rubocop
git add -A && git commit -m "feat: emails index + inspector drawer with CSP-sandboxed preview and raw .eml download"
```

Manual check: `bin/dev` — open Emails, click a row (drawer opens), check preview iframe, download `.eml`, dark mode.

---

### Task 7: `Email#resend` + `Emails::ResendsController`

**Files:**
- Create: `app/models/email/resendable.rb`, `app/controllers/emails/resends_controller.rb`
- Modify: `app/models/email.rb` (include), `app/views/emails/show.html.erb` (button)
- Test: Create `test/models/email/resendable_test.rb`, `test/controllers/emails/resends_controller_test.rb`

**Interfaces:**
- Consumes: `EmailSubmission` (full validation matrix incl. suppression), `Email::MimeStore.read`, `Mail` gem, `EmailScoped`, `authorize_capability! :send`.
- Produces: `Email#resend` → the new queued `Email`, or `false` (validation failure — e.g. suppressed recipients — or attachments whose archived `.eml` was pruned); `Email.retry_soft_bounces(limit:)` (class method, added here because it reuses `resend`; consumed by Task 8); `POST /emails/:email_id/resend`.
- **User decision:** attachments are reconstructed by re-parsing the archived `.eml` — full-fidelity resend. Metadata-only fallback is not acceptable; if the `.eml` is gone and the email had attachments, resend refuses.

- [ ] **Step 1: Write the failing model tests** — create `test/models/email/resendable_test.rb`:

```ruby
require "test_helper"

class Email::ResendableTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    @project = projects(:acme_default)
  end

  test "resend queues a copy tagged with the original id" do
    original = submit_email(to: [ "again@example.com" ])

    resent = assert_difference -> { Email.count }, +1 do
      original.resend
    end

    assert_equal "queued", resent.status
    assert_equal original.public_id, resent.tags["resent_from"]
    assert_equal [ "again@example.com" ], resent.recipients.kind_to.pluck(:address)
    assert_equal original.subject, resent.subject
  end

  test "resend enqueues delivery" do
    original = submit_email(to: [ "again@example.com" ])

    assert_enqueued_with(job: SendEmailJob) do
      original.resend
    end
  end

  test "resend reconstructs attachments from the archived eml" do
    original = submit_email(to: [ "files@example.com" ],
      attachments: [ { filename: "hello.txt", content_type: "text/plain",
        content: Base64.strict_encode64("hello world") } ])

    resent = original.resend

    assert_equal [ "hello.txt" ], resent.attachments.pluck(:filename)
    assert_includes Email::MimeStore.read(resent), Base64.strict_encode64("hello world").scan(/.{1,60}/).first
  end

  test "resend refuses when recipients are now suppressed" do
    original = submit_email(to: [ "later-blocked@example.com" ])
    Suppression.record(@project, "later-blocked@example.com", reason: "complaint")

    assert_no_difference -> { Email.count } do
      assert_not original.resend
    end
  end

  test "resend refuses when attachments existed but the eml was pruned" do
    original = submit_email(to: [ "files@example.com" ],
      attachments: [ { filename: "hello.txt", content_type: "text/plain",
        content: Base64.strict_encode64("hello world") } ])
    Email::MimeStore.delete(original)
    original.update!(mime_path: nil)

    assert_not original.resend
  end

  test "retry_soft_bounces resends only transient bounces up to the limit and skips suppressed" do
    wipe_send_domain
    soft_one = submit_email(to: [ "soft1@example.com" ])
    soft_two = submit_email(to: [ "soft2@example.com" ])
    hard = submit_email(to: [ "hard@example.com" ])
    [ soft_one, soft_two ].each { |email| email.update_columns(status: "bounced", bounce_type: "transient") }
    hard.update_columns(status: "bounced", bounce_type: "permanent")
    Suppression.record(@project, "soft2@example.com", reason: "complaint")

    count = assert_difference -> { Email.count }, +1 do
      @project.emails.retry_soft_bounces(limit: 100)
    end
    assert_equal 1, count
    assert_equal "soft1@example.com", Email.order(:id).last.recipients.kind_to.first.address
  end

  private
    def submit_email(to:, attachments: [])
      EmailSubmission.new(project: @project, source: sources(:acme_production), from: "hello@acme.com",
        to: to, subject: "Resend me", text: "Body", attachments: attachments).save
    end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/models/email/resendable_test.rb`
Expected: FAIL — `resend` undefined.

- [ ] **Step 3: Implement the concern** — create `app/models/email/resendable.rb`:

```ruby
module Email::Resendable
  extend ActiveSupport::Concern

  class_methods do
    def retry_soft_bounces(limit: 100)
      soft_bounced.reverse_chronologically.limit(limit).to_a.count { |email| email.resend }
    end
  end

  # Rebuilds a fresh submission from the stored fields and the archived MIME
  # (attachment bytes only exist inside the .eml), so the copy runs the full
  # validation matrix — including suppression — before entering the queue.
  def resend
    if resendable?
      EmailSubmission.new(resubmission_attributes).save
    else
      false
    end
  end

  private
    def resendable?
      attachments.none? || mime_path.present?
    end

    def resubmission_attributes
      { project: project, source: source, from: from, subject: subject,
        html: html_body, text: text_body,
        to: recipients.kind_to.pluck(:address),
        cc: recipients.kind_cc.pluck(:address),
        bcc: recipients.kind_bcc.pluck(:address),
        headers: headers, tags: tags.merge("resent_from" => public_id),
        attachments: archived_attachments }
    end

    def archived_attachments
      if attachments.none?
        []
      else
        Mail.new(Email::MimeStore.read(self)).attachments.map do |part|
          { filename: part.filename, content_type: part.mime_type,
            content: Base64.strict_encode64(part.body.decoded) }
        end
      end
    end
end
```

Include it in `app/models/email.rb`:

```ruby
  include Statuses, Deliverable, Resendable, Broadcastable
```

- [ ] **Step 4: Run the model tests**

Run: `bin/rails test test/models/email/resendable_test.rb`
Expected: PASS.

- [ ] **Step 5: Controller + tests**

Create `test/controllers/emails/resends_controller_test.rb`:

```ruby
require "test_helper"

class Emails::ResendsControllerTest < ActionDispatch::IntegrationTest
  test "resending queues a copy" do
    sign_in_as users(:owner)
    email = EmailSubmission.new(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", to: [ "again@example.com" ], subject: "Once more", text: "Body").save

    assert_difference -> { Email.count }, +1 do
      post email_resend_url(email)
    end

    assert_redirected_to email_url(Email.order(:id).last)
  end

  test "a suppressed recipient blocks the resend with an alert" do
    sign_in_as users(:owner)
    email = EmailSubmission.new(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", to: [ "will-block@example.com" ], subject: "Nope", text: "Body").save
    Suppression.record(projects(:acme_default), "will-block@example.com", reason: "complaint")

    assert_no_difference -> { Email.count } do
      post email_resend_url(email)
    end

    assert_redirected_to email_url(email)
    assert_equal "Email could not be resent — recipients may be suppressed.", flash[:alert]
  end

  test "requires the send capability" do
    sign_in_as users(:read_only)
    post email_resend_url(emails(:acme_delivered))

    assert_response :forbidden
  end

  test "cross-tenant resends 404" do
    sign_in_as users(:owner)
    post email_resend_url(emails(:globex_delivered))

    assert_response :not_found
  end
end
```

Create `app/controllers/emails/resends_controller.rb`:

```ruby
class Emails::ResendsController < ApplicationController
  include EmailScoped

  before_action -> { authorize_capability! :send }

  def create
    if resent = @email.resend
      redirect_to email_path(resent), notice: "Email queued for resend."
    else
      redirect_to email_path(@email), alert: "Email could not be resent — recipients may be suppressed."
    end
  end
end
```

(`EmailScoped` is included first so cross-tenant requests 404 before the capability check can 403.)

Add the resend button to `app/views/emails/show.html.erb`'s footer (inside the existing `<footer>`):

```erb
      <% if Current.workspace.capability?(Current.user, :send) %>
        <%= button_to "Resend", email_resend_path(@email), class: "btn btn--primary btn--medium", data: { turbo_frame: "_top" } %>
      <% end %>
```

Flash display: the layout has no flash rendering yet — add above `<%= yield %>` in `application.html.erb`:

```erb
      <% if notice.present? %><p class="flash txt-positive pad-block-half"><%= notice %></p><% end %>
      <% if alert.present? %><p class="flash txt-negative pad-block-half"><%= alert %></p><% end %>
```

- [ ] **Step 6: Run, full suite, rubocop, commit**

```bash
bin/rails test test/controllers/emails/resends_controller_test.rb
bin/rails test && bin/rubocop
git add -A && git commit -m "feat: Email#resend with .eml attachment reconstruction; capability-gated resends"
```

---

### Task 8: Suppressions, bounces, retries, CSV exports

**Files:**
- Modify: `Gemfile` (`gem "csv"`), `config/routes.rb`, `app/views/layouts/_nav.html.erb`, `app/views/emails/index.html.erb` (export link)
- Modify: `app/models/email.rb`, `app/models/suppression.rb` (`to_csv`)
- Create: `app/controllers/suppressions_controller.rb`, `app/controllers/bounces_controller.rb`, `app/controllers/bounces/retries_controller.rb`, `app/controllers/exports_controller.rb`
- Create: `app/views/suppressions/index.html.erb`, `app/views/bounces/index.html.erb`
- Test: Create `test/controllers/suppressions_controller_test.rb`, `test/controllers/bounces_controller_test.rb`, `test/controllers/bounces/retries_controller_test.rb`, `test/controllers/exports_controller_test.rb`

**Interfaces:**
- Consumes: `hard_bounced`/`soft_bounced`/`indexed_by` scopes, `Email.retry_soft_bounces` (Task 7), `Suppression.record`/`.active`, `emails/_status_pill`.
- Produces: `Email.to_csv` / `Suppression.to_csv` (class methods on the current scope); routes `resources :suppressions, only: %i[index create destroy]`, `resources :bounces, only: :index` + nested `resource :retry`, `resources :exports, only: :show` with `id ∈ emails|suppressions|bounces`.
- Capability policy: suppression create/destroy and bounce retry mutate send behavior → `authorize_capability! :send`; the index/export pages are readable by any member.

- [ ] **Step 1: Gemfile**

Add near the top-level gems: `gem "csv"` then run `bundle install`.

- [ ] **Step 2: Write the failing tests**

`test/controllers/suppressions_controller_test.rb`:

```ruby
require "test_helper"

class SuppressionsControllerTest < ActionDispatch::IntegrationTest
  test "index lists the project's suppressions" do
    sign_in_as users(:owner)
    get suppressions_url

    assert_response :success
    assert_select "body", text: /blocked@example.com/
  end

  test "create records a manual suppression" do
    sign_in_as users(:owner)

    assert_difference -> { Suppression.count }, +1 do
      post suppressions_url, params: { suppression: { email: "  NoMore@Example.com " } }
    end

    suppression = Suppression.order(:id).last
    assert_equal "nomore@example.com", suppression.email
    assert_equal "manual", suppression.reason
    assert_equal projects(:acme_default), suppression.project
  end

  test "create rejects a blank address with an alert" do
    sign_in_as users(:owner)

    assert_no_difference -> { Suppression.count } do
      post suppressions_url, params: { suppression: { email: "" } }
    end

    assert_redirected_to suppressions_url
    assert flash[:alert].present?
  end

  test "destroy removes a suppression from the current project only" do
    sign_in_as users(:owner)

    assert_difference -> { Suppression.count }, -1 do
      delete suppression_url(suppressions(:acme_blocked))
    end
  end

  test "mutations require the send capability" do
    sign_in_as users(:read_only)

    post suppressions_url, params: { suppression: { email: "x@example.com" } }
    assert_response :forbidden

    delete suppression_url(suppressions(:acme_blocked))
    assert_response :forbidden
  end
end
```

`test/controllers/bounces_controller_test.rb`:

```ruby
require "test_helper"

class BouncesControllerTest < ActionDispatch::IntegrationTest
  test "index defaults to all bounces and splits hard and soft" do
    sign_in_as users(:owner)
    get bounces_url

    assert_response :success
    assert_select "body", text: /Password reset/
    assert_select "body", text: /Mailbox full retry/

    get bounces_url(filter: "hard_bounces")
    assert_select "body", text: /Password reset/
    assert_select "body", { text: /Mailbox full retry/, count: 0 }

    get bounces_url(filter: "soft_bounces")
    assert_select "body", text: /Mailbox full retry/
    assert_select "body", { text: /Password reset/, count: 0 }
  end
end
```

`test/controllers/bounces/retries_controller_test.rb`:

```ruby
require "test_helper"

class Bounces::RetriesControllerTest < ActionDispatch::IntegrationTest
  test "retrying re-queues soft bounces and reports the count" do
    sign_in_as users(:owner)
    Email.soft_bounced.update_all(bounce_type: nil) # unclassify fixture rows so only the controlled email retries
    email = EmailSubmission.new(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", to: [ "retry@example.com" ], subject: "Bounced softly", text: "Body").save
    email.update_columns(status: "bounced", bounce_type: "transient")

    assert_difference -> { Email.count }, +1 do
      post bounces_retry_url
    end

    assert_redirected_to bounces_url
    assert_match(/1 email/, flash[:notice])
  end

  test "requires the send capability" do
    sign_in_as users(:read_only)
    post bounces_retry_url

    assert_response :forbidden
  end
end
```

`test/controllers/exports_controller_test.rb`:

```ruby
require "test_helper"

class ExportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
  end

  test "emails export streams project-scoped CSV" do
    get export_url("emails")

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_includes response.body, "public_id,status,from,subject"
    assert_includes response.body, emails(:acme_delivered).public_id
    assert_not_includes response.body, emails(:globex_delivered).public_id
  end

  test "bounces export only includes bounced emails" do
    get export_url("bounces")

    assert_includes response.body, emails(:acme_hard_bounce).public_id
    assert_not_includes response.body, emails(:acme_delivered).public_id
  end

  test "suppressions export includes address and reason" do
    get export_url("suppressions")

    assert_includes response.body, "blocked@example.com"
    assert_includes response.body, "complaint"
  end

  test "unknown exports 404" do
    get export_url("users")

    assert_response :not_found
  end
end
```

- [ ] **Step 3: Run to verify failure**

Run: `bin/rails test test/controllers/suppressions_controller_test.rb test/controllers/bounces_controller_test.rb test/controllers/bounces/retries_controller_test.rb test/controllers/exports_controller_test.rb`
Expected: FAIL — routes missing.

- [ ] **Step 4: Implement**

`config/routes.rb` — after the emails block:

```ruby
  resources :suppressions, only: %i[ index create destroy ]

  resources :bounces, only: :index
  scope module: :bounces, path: :bounces, as: :bounces do
    resource :retry, only: :create
  end

  resources :exports, only: :show
```

CSV class methods. In `app/models/email.rb` (class method, above the instance methods):

```ruby
  def self.to_csv
    CSV.generate(headers: true) do |csv|
      csv << %w[ public_id status bounce_type from subject recipients created_at ]
      preloaded.find_each do |email|
        csv << [ email.public_id, email.status, email.bounce_type, email.from, email.subject,
          email.recipients.map(&:address).join(" "), email.created_at.iso8601 ]
      end
    end
  end
```

In `app/models/suppression.rb` (inside the existing `class << self`):

```ruby
    def to_csv
      CSV.generate(headers: true) do |csv|
        csv << %w[ email reason expires_at created_at ]
        find_each do |suppression|
          csv << [ suppression.email, suppression.reason, suppression.expires_at&.iso8601,
            suppression.created_at.iso8601 ]
        end
      end
    end
```

`app/controllers/suppressions_controller.rb`:

```ruby
class SuppressionsController < ApplicationController
  before_action -> { authorize_capability! :send }, only: %i[ create destroy ]

  def index
    @suppressions = Current.project.suppressions.order(created_at: :desc)
  end

  def create
    Suppression.record(Current.project, suppression_params[:email], reason: "manual")
    redirect_to suppressions_path, notice: "Address suppressed."
  rescue ActiveRecord::RecordInvalid => invalid
    redirect_to suppressions_path, alert: invalid.record.errors.full_messages.to_sentence
  end

  def destroy
    Current.project.suppressions.find(params[:id]).destroy
    redirect_to suppressions_path, notice: "Suppression removed."
  end

  private
    def suppression_params
      params.require(:suppression).permit(:email)
    end
end
```

`app/controllers/bounces_controller.rb`:

```ruby
class BouncesController < ApplicationController
  def index
    @emails = Current.project.emails.indexed_by(params[:filter].presence || "bounced")
      .reverse_chronologically.preloaded.limit(100)
  end
end
```

`app/controllers/bounces/retries_controller.rb`:

```ruby
class Bounces::RetriesController < ApplicationController
  before_action -> { authorize_capability! :send }

  def create
    count = Current.project.emails.retry_soft_bounces(limit: 100)
    redirect_to bounces_path, notice: "#{count} #{"email".pluralize(count)} re-queued."
  end
end
```

`app/controllers/exports_controller.rb`:

```ruby
class ExportsController < ApplicationController
  def show
    if csv = csv_for(params[:id])
      send_data csv, filename: "#{params[:id]}-#{Date.current.iso8601}.csv", type: "text/csv"
    else
      head :not_found
    end
  end

  private
    def csv_for(kind)
      case kind
      when "emails" then Current.project.emails.to_csv
      when "bounces" then Current.project.emails.bounced.to_csv
      when "suppressions" then Current.project.suppressions.to_csv
      end
    end
end
```

`app/views/suppressions/index.html.erb`:

```erb
<div class="flex align-center justify-space-between margin-block">
  <h1 class="margin-none txt-large">Suppressions</h1>
  <%= link_to "Export CSV", export_path("suppressions"), class: "btn btn--plain btn--medium", data: { turbo: false } %>
</div>

<% if Current.workspace.capability?(Current.user, :send) %>
  <%= form_with model: Suppression.new, url: suppressions_path, class: "flex align-center gap-half margin-block" do |form| %>
    <%= form.email_field :email, placeholder: "address@example.com", class: "input", required: true %>
    <button type="submit" class="btn btn--primary btn--medium">Suppress address</button>
  <% end %>
<% end %>

<div class="emails-table">
  <% if @suppressions.any? %>
    <% @suppressions.each do |suppression| %>
      <div class="emails-table__row">
        <span class="font-weight-bold flex-1"><%= suppression.email %></span>
        <span class="txt-small txt-subtle"><%= suppression.reason %></span>
        <span class="txt-x-small txt-subtle">
          <%= suppression.expires_at ? "expires #{l suppression.expires_at, format: :short}" : "permanent" %>
        </span>
        <% if Current.workspace.capability?(Current.user, :send) %>
          <%= button_to suppression_path(suppression), method: :delete, class: "btn btn--plain btn--medium", aria: { label: "Remove suppression" } do %>
            <%= icon_tag "trash" %>
          <% end %>
        <% end %>
      </div>
    <% end %>
  <% else %>
    <p class="txt-subtle pad">No suppressed addresses.</p>
  <% end %>
</div>
```

`app/views/bounces/index.html.erb`:

```erb
<div class="flex align-center justify-space-between margin-block">
  <h1 class="margin-none txt-large">Bounces</h1>
  <div class="flex align-center gap-half">
    <%= link_to "Export CSV", export_path("bounces"), class: "btn btn--plain btn--medium", data: { turbo: false } %>
    <% if Current.workspace.capability?(Current.user, :send) %>
      <%= button_to "Retry soft bounces", bounces_retry_path, class: "btn btn--primary btn--medium" %>
    <% end %>
  </div>
</div>

<nav class="flex gap-half margin-block" aria-label="Bounce type">
  <%= link_to "All", bounces_path, class: "btn btn--plain btn--medium #{"btn--current" if params[:filter].blank?}" %>
  <%= link_to "Hard", bounces_path(filter: "hard_bounces"), class: "btn btn--plain btn--medium #{"btn--current" if params[:filter] == "hard_bounces"}" %>
  <%= link_to "Soft", bounces_path(filter: "soft_bounces"), class: "btn btn--plain btn--medium #{"btn--current" if params[:filter] == "soft_bounces"}" %>
</nav>

<div class="emails-table">
  <% if @emails.any? %>
    <%= render partial: "emails/email", collection: @emails %>
  <% else %>
    <p class="txt-subtle pad">No bounces in this queue.</p>
  <% end %>
</div>
```

(If `buttons.css` lacks a `.btn--current` modifier, add one there — components layer — mirroring the primary background at reduced emphasis.)

Nav links in `_nav.html.erb` (after Emails):

```erb
  <%= link_to "Bounces", bounces_path, class: "nav__link", aria: { current: current_page?(bounces_path) ? "page" : nil } %>
  <%= link_to "Suppressions", suppressions_path, class: "nav__link", aria: { current: current_page?(suppressions_path) ? "page" : nil } %>
```

Export link on `app/views/emails/index.html.erb` (in the header actions, before the search form):

```erb
      <%= link_to "Export CSV", export_path("emails"), class: "btn btn--plain btn--medium", data: { turbo: false } %>
```

Guard `Current.project` in these controllers the same way as `EmailsController#index` if `Current.project` can be nil (workspace with no active project): wrap the body in `if Current.project` and render the empty state, mirroring the dashboard view.

- [ ] **Step 5: Run, full suite, rubocop, commit**

```bash
bin/rails test test/controllers/suppressions_controller_test.rb test/controllers/bounces_controller_test.rb test/controllers/bounces/retries_controller_test.rb test/controllers/exports_controller_test.rb
bin/rails test && bin/rubocop
git add -A && git commit -m "feat: suppression management, bounce queues with soft-retry, CSV exports"
```

---

### Task 9: Send-test form

**Files:**
- Modify: `config/routes.rb`, `app/views/layouts/_nav.html.erb`
- Create: `app/controllers/test_emails_controller.rb`, `app/views/test_emails/new.html.erb`
- Test: Create `test/controllers/test_emails_controller_test.rb`

**Interfaces:**
- Consumes: `EmailSubmission`, the project's first source, `authorize_capability! :send`.
- Produces: `GET /test_emails/new`, `POST /test_emails`. `TestEmail` is a route-level noun only — no model; the create builds a real `EmailSubmission` against `Current.project`.

- [ ] **Step 1: Write the failing tests** — create `test/controllers/test_emails_controller_test.rb`:

```ruby
require "test_helper"

class TestEmailsControllerTest < ActionDispatch::IntegrationTest
  test "new renders the form" do
    sign_in_as users(:owner)
    get new_test_email_url

    assert_response :success
    assert_select "form[action=?]", test_emails_path
  end

  test "create queues a test email through the full submission pipeline" do
    sign_in_as users(:owner)

    assert_difference -> { Email.count }, +1 do
      assert_enqueued_with(job: SendEmailJob) do
        post test_emails_url, params: { email_submission: {
          from: "hello@acme.com", to: "me@example.com", subject: "Test send", text: "It works" } }
      end
    end

    assert_redirected_to email_url(Email.order(:id).last)
  end

  test "validation errors re-render the form" do
    sign_in_as users(:owner)

    assert_no_difference -> { Email.count } do
      post test_emails_url, params: { email_submission: { from: "", to: "", subject: "", text: "" } }
    end

    assert_response :unprocessable_entity
    assert_select ".txt-negative"
  end

  test "requires the send capability" do
    sign_in_as users(:read_only)
    get new_test_email_url
    assert_response :forbidden

    post test_emails_url, params: { email_submission: { from: "a@b.c", to: "d@e.f", subject: "x", text: "y" } }
    assert_response :forbidden
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/controllers/test_emails_controller_test.rb`
Expected: FAIL — route missing.

- [ ] **Step 3: Implement**

`config/routes.rb`:

```ruby
  resources :test_emails, only: %i[ new create ]
```

`app/controllers/test_emails_controller.rb`:

```ruby
class TestEmailsController < ApplicationController
  before_action -> { authorize_capability! :send }

  def new
    @submission = EmailSubmission.new(project: Current.project, source: default_source)
  end

  def create
    @submission = EmailSubmission.new(submission_params.merge(project: Current.project, source: default_source))

    if email = @submission.save
      redirect_to email_path(email), notice: "Test email queued."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private
    def default_source
      Current.project&.sources&.order(:id)&.first
    end

    def submission_params
      params.require(:email_submission).permit(:from, :to, :subject, :html, :text)
    end
end
```

(`EmailSubmission#to=` wraps a single string into an array; `validates :source, presence: true` covers projects with no source.)

`app/views/test_emails/new.html.erb`:

```erb
<h1 class="txt-large margin-block">Send a test email</h1>

<% if @submission.errors.any? %>
  <div class="txt-negative txt-small margin-block-half">
    <p class="font-weight-bold margin-none">The test email couldn't be sent:</p>
    <ul class="margin-none">
      <% @submission.errors.full_messages.each do |message| %>
        <li><%= message %></li>
      <% end %>
    </ul>
  </div>
<% end %>

<%= form_with model: @submission, url: test_emails_path, class: "flex flex-column gap", style: "max-inline-size: 40rem;" do |form| %>
  <div class="flex flex-column gap-half">
    <label for="email_submission_from">From</label>
    <%= form.email_field :from, class: "input", required: true %>
  </div>
  <div class="flex flex-column gap-half">
    <label for="email_submission_to">To</label>
    <%= form.email_field :to, value: Array(@submission.to).first, class: "input", required: true %>
  </div>
  <div class="flex flex-column gap-half">
    <label for="email_submission_subject">Subject</label>
    <%= form.text_field :subject, class: "input", required: true %>
  </div>
  <div class="flex flex-column gap-half">
    <label for="email_submission_text">Text body</label>
    <%= form.text_area :text, class: "input input--textarea", rows: 4 %>
  </div>
  <div class="flex flex-column gap-half">
    <label for="email_submission_html">HTML body (optional)</label>
    <%= form.text_area :html, class: "input input--textarea", rows: 4 %>
  </div>
  <div>
    <button type="submit" class="btn btn--secondary btn--large">Send test</button>
  </div>
<% end %>
```

(If `inputs.css` lacks the `--textarea` modifier, add it there per the style guide.)

Nav link in `_nav.html.erb` (last):

```erb
  <%= link_to "Send test", new_test_email_path, class: "nav__link", aria: { current: current_page?(new_test_email_path) ? "page" : nil } %>
```

- [ ] **Step 4: Run, full suite, rubocop, commit**

```bash
bin/rails test test/controllers/test_emails_controller_test.rb
bin/rails test && bin/rubocop
git add -A && git commit -m "feat: send-test form through the full EmailSubmission pipeline"
```

---

### Task 10: Phase wrap-up

- [ ] **Step 1: Full CI**

Run: `bin/ci`
Expected: setup, rubocop, bundler-audit, importmap audit, brakeman, tests, seed replant — all green. Fix anything it surfaces (likely candidates: brakeman on the preview action if Task 6's ignore entry was skipped; seeds if they touch emails).

- [ ] **Step 2: Manual light/dark + live pass**

`bin/dev`: walk Dashboard → Activity → Emails (open inspector, preview, download, resend) → Bounces (tabs, retry) → Suppressions (add/remove, export) → Send test. Toggle dark mode (`document.documentElement.dataset.theme = "dark"` in the console or OS setting). From `bin/rails console`, `Email.last.apply_event("delivery")` while watching `/activity`.

- [ ] **Step 3: Standards greps (project-level verification from the master plan)**

```bash
rg "def \w+!" app/     # only bang methods with non-bang counterparts
rg "oklch\(|rgb\(|#[0-9a-fA-F]{3,6}" app/assets/stylesheets/nav.css app/assets/stylesheets/metrics.css app/assets/stylesheets/activity.css app/assets/stylesheets/emails.css app/assets/stylesheets/status_pill.css
```

The second grep should only hit token *fallback-free* usages (`var(--…)`); the one deliberate exception is `oklch(var(--lch-black) / 40%)` in the drawer backdrop (token-composed, acceptable) and `background-color: white` on the preview iframe (emails assume a white canvas — annotate with a comment if the reviewer objects).

- [ ] **Step 4: Update the master plan + record outcomes**

In `docs/plans/departures-execution-plan.md`, mark Phase 4's detailed plan as complete (mirror how Phases 2–3 are annotated). Append a "Final-review outcomes" section to THIS file after the phase code-review (deviations, adjudications, anything deferred to Phase 5 — e.g. the outbound-webhook seam remains no-op, template resolution still rejected by `EmailSubmission`).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "docs: phase 4 wrap-up — plan status, review outcomes"
```

---

## Phase-level verification (maps to the master plan's Phase 4 test list)

- Filter scopes: every `indexed_by` branch, `hard_bounced`/`soft_bounced` on `bounce_type`, `in_time_range` boundaries, injection-safe `search`, `preloaded` eager loads — `test/models/email_test.rb`.
- Live activity: `turbo-cable-stream-source` present, project-scoped rows, filters — `test/controllers/activity_controller_test.rb`; broadcast itself already covered by `test/models/broadcastable_test.rb`.
- Metrics: event-derived funnel, zero-denominator guards, prior-period deltas, zero-filled sparkline buckets, cache-key busting, `metrics_for` factory — `test/models/project/metrics_test.rb`.
- Inspector: CSP + X-Frame headers on preview, `message/rfc822` raw download, 404 on pruned MIME, cross-tenant 404 — `test/controllers/emails_controller_test.rb`.
- Resend: tagged copy, enqueued delivery, `.eml` attachment round-trip, suppressed-recipient block, capability 403, refuses when attachments' `.eml` is pruned — `test/models/email/resendable_test.rb`, `test/controllers/emails/resends_controller_test.rb`.
- Bounce ops: hard/soft queues, `retry_soft_bounces` limit + suppression skip + count, capability 403 — bounces tests.
- Exports: tenant-scoped CSV for emails/bounces/suppressions, unknown id 404 — `test/controllers/exports_controller_test.rb`.
- Send test: full pipeline enqueue, validation re-render, capability 403 — `test/controllers/test_emails_controller_test.rb`.
- `bin/rails test`, `bin/rubocop`, `bin/ci` all green at phase end.

## Final-review outcomes (recorded post-execution)

- **Plan defects fixed during implementation — do not copy these patterns into future plans:** (1) the `search` scope's verbatim SQL failed its own test: SQLite ignores `sanitize_sql_like`'s backslash escaping unless every `LIKE` carries an explicit `ESCAPE '\'` clause — production code adds it to all four clauses. (2) `Email.to_csv`'s sample column order (`bounce_type` between `status` and `from`) contradicted the plan's own verbatim test assertion `"public_id,status,from,subject"` — `bounce_type` moved after `subject`. (3) The attachment round-trip assertion grepped for a base64 chunk, but the `mail` gem stores short ASCII `text/plain` attachments inline 7bit — replaced with an encoding-agnostic decode-and-compare. (4) The style guide's textarea and actor-input snippets referenced `calc()` on a two-value `--input-padding` shorthand and non-existent tokens (`--input-border-size`, `--color-selected-dark`) — both `docs/style-guide.md` snippets corrected to match the working `inputs.css`.
- **Whole-branch review (fable): no Criticals; five Importants, all fixed in wave `0c5460a` + polish `2a9baa6`:** nil-`Current.project` 500s on exports/retries/suppressions → shared `RequiresProject` concern raising `RecordNotFound` (suppressions index kept the friendly empty state via `skip_before_action`); dashboard fragment cache had no TTL so idle projects served frozen time-windowed metrics forever → `expires_in: 60.seconds`; preview CSP lacked `form-action`/`base-uri` (neither falls back to `default-src`, leaving a same-origin phishing-form vector when the preview URL is opened directly) → both set to `'none'`; `.input--actor` was used by two views but never implemented; **plan-defect: `retry_soft_bounces` was not idempotent — every click re-sent all soft bounces** → `emails.resent_at` column, stamped transactionally with the copy inside `Email#resend`, retry scope `where(resent_at: nil)`; manual per-email resend intentionally remains repeatable.
- **Post-task security scan catch:** CSV formula injection in both exports (customer-controlled subject/from/recipients/email/reason cells) → `csv_safe` prefix-neutralization (`'` before `=+-@`, tab, CR), fixed in `b916918` with an end-to-end `=HYPERLINK` test.
- **Deferred to Phase 5/6:** `csv_safe` extraction to a shared home when a third exporter appears (+ six-prefix unit test); `raw` 404 when `mime_path` is set but the file is missing on disk (currently 500s); drawer Esc-close leaves the turbo frame stale (`close->drawer#close` action); sparkline drops the partial oldest bucket (sum < sent_count at window edge); funnel rates can exceed 100% (events counted by `occurred_at` against emails by `created_at` — accepted dashboard approximation, comment before "fixing"); bounces CSV export ignores the hard/soft tab filter; concurrent bulk retries could still double-send (claim-style `update_all` CAS if this grows an API surface); `--inline-space-double` token undefined (metrics.css uses its `2ch` fallback); `.flash` class unstyled; SES "Undetermined" bounces classify as `transient` and thus enter the retry queue (plan-mandated mapping — revisit with Phase 5 guardrails).
- **Accepted policies:** nil-project empty states on index pages vs `RequiresProject` 404s on mutations/exports (per-page choice is deliberate); `sandbox="allow-same-origin"` on the preview iframe (scripts blocked by CSP; needed for nothing but kept harmless); preview `img-src *` tracking-pixel exposure (customer HTML phones home on preview — revisit with a proxy if privacy posture tightens).
- **Manual browser pass (plan Task 10 Step 2) PENDING** — walk Dashboard → Activity (live morph) → Emails (drawer/preview/raw/resend) → Bounces → Suppressions → Send test in light + dark before merging.
- Final state: 308 runs / 1170 assertions green, rubocop clean, brakeman 0 warnings, `bin/ci` green at `2a9baa6`.

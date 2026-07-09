# Phase 3 — SNS Ingestion, Events, Suppressions, Live Activity — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the feedback loop: SES/SNS event notifications hit `POST /api/webhooks/ses/:webhook_token`, get signature-verified and logged, then a background job matches them to emails, records `EmailEvent` rows, advances email status, suppresses complained/hard-bounced addresses, and broadcasts a live refresh to the project activity stream.

**Architecture:** Everything follows `docs/patterns-and-best-practices.md`: a thin `Webhooks::SesController` (verify → log → `process_later`, zero business logic), ALL ingestion logic in `WebhookLog#process` behind a 3-line `ProcessSesEventJob` (§4.4), a pure-Ruby `Sns::MessageVerifier` in `lib/` (risk #1), an `Email::SesEvent` value object normalizing SES payload shapes (§3.4), and a `Broadcastable` model concern emitting Turbo Stream refreshes to `[project, :activity]` (consumed by Phase 4's dashboard). A prerequisite task makes `Email::Statuses#advance_to` a row-guarded write so concurrent SNS workers can never regress status (Phase 2 final-review finding, risk #4).

**Tech Stack:** Rails 8.1, OpenSSL + Net::HTTP (stdlib — no new gems), turbo-rails 2.0 (`broadcast_refresh_to` over Solid Cable), Solid Queue.

## Global Constraints

- Default integer primary keys. **No new gems** — SNS verification is hand-rolled on OpenSSL; HTTP via Net::HTTP.
- Bang rule (§5.1): `apply_event`, `mark_sending`, `mark_sent`, `mark_failed` — no bangs anywhere in this phase.
- Inbound route is `POST /api/webhooks/ses/:webhook_token`, throttled `rate_limit to: 120, within: 1.minute` keyed by the token param. Unknown token → 404 (no log row). Bad signature → 403 with the log kept (`status: failed`).
- **SNS posts JSON with `Content-Type: text/plain`** — Rails will NOT parse it into `params`. The controller must `JSON.parse(request.body.read)` (malformed → 400).
- Signing-cert host is pinned to exactly `sns.#{source.region}.amazonaws.com` over https with a `.pem` path. `SignatureVersion` `"1"` → SHA1, `"2"` → SHA256; anything else fails verification. `SubscribeURL` auto-confirmation only ever GETs an https URL whose host matches `sns.<region>.amazonaws.com`.
- Event matching key is `(source_id, ses_message_id)` — never a bare `ses_message_id` lookup, so one tenant's events can never touch another tenant's email.
- Suppress on **complaint + permanent bounce ONLY**. `bounceType` `"Transient"` and `"Undetermined"` never suppress. Re-suppressing an address whose suppression row expired must reactivate that row (`expires_at: nil`) — the unique `(project_id, email)` index means a blind `create!` would blow up.
- Unmatched-event policy: mark the log `unmatched`, keep the full payload for forensics, create no events, raise nothing.
- `EmailEvent` rows are ALWAYS recorded for a matched email, even when the status doesn't advance (out-of-order events, `delivery_delay`) — the activity feed needs the history; only the status is monotonic.
- **Prerequisite carried in from Phase 2's final review (Task 1):** `Email::Statuses#advance_to` becomes a row-guarded `update_all` (compare-and-set in the WHERE clause) because SQLite has no `SELECT … FOR UPDATE`; `ses_message_id` folds into `mark_sent(ses_message_id:)` to halve the writes. `update_all` **skips callbacks** — the Task 7 broadcast is therefore invoked explicitly from `advance_to`, not from an `after_update_commit`.
- `Current.session = sessions(:owner)` in every model-test setup (gotcha §7.3.1). No webmock — outbound HTTP is stubbed with `Minitest::Mock`/`stub`, SES untouched this phase.
- Style §5.1: expanded conditionals (guard only at the start of a non-trivial body), class methods → public (`initialize` first) → private, private methods indented and in invocation order.
- Every task ends with `bin/rails test` green and a commit. Run `bin/rubocop -a` before each commit.

**Task prelude (all tasks):** re-read patterns doc Part 2 (concerns, intention-revealing APIs) and §5.1 (style). Task 5 additionally: §4.4–4.5 (`_now/_later`, ActiveJob workspace extension). Task 6 additionally: Part 4.1–4.3 (thin controllers) and `app/controllers/api/base_controller.rb` (the existing `rate_limit` precedent, risk #5). No task in this phase touches views or CSS.

---

### Task 1 (Phase 3 prerequisite): race-safe advance_to + ses_message_id fold

**Files:**
- Modify: `app/models/email/statuses.rb`, `app/models/email/deliverable.rb`
- Test: `test/models/email/statuses_test.rb` (append)

**Interfaces:**
- Consumes: `STATUS_PRECEDENCE` and the existing `advance_to(new_status, **attributes)` (Phase 1).
- Produces: `advance_to` performs `WHERE id = ? AND status IN (<lower-precedence>)` + `update_all`, then `reload`s — safe against concurrent writers on SQLite (no `FOR UPDATE` available), keeps its true/false return contract. `mark_sent(**attributes)` accepts `ses_message_id:` so `deliver` persists the id and the advance in ONE write. Consumed by every later task that calls `apply_event` from the SNS worker while `deliver` may still be running.
- **Why the fold is safe:** an SNS event can only match an email through its persisted `ses_message_id` — until `mark_sent` writes it, no event can have advanced this row past `sending`, so the guarded UPDATE cannot lose the id.

- [ ] **Step 1: Write the failing tests**

Append inside the class in `test/models/email/statuses_test.rb` (the new tests create their own email so they're independent of the file's existing setup):

```ruby
  # --- Phase 3 prerequisite: row-guarded advance (risk #4) ---

  test "a stale in-memory copy cannot regress a concurrently advanced status" do
    email = fresh_email
    concurrent_copy = Email.find(email.id)
    concurrent_copy.apply_event("delivery")

    assert_not email.mark_sent, "the guarded write must match zero rows"
    assert_equal "delivered", email.status, "advance_to must reload so memory matches the row"
  end

  test "mark_sent persists the ses message id in the same guarded write" do
    email = fresh_email

    assert email.mark_sent(ses_message_id: "ses-fold-1")
    assert_equal "ses-fold-1", email.reload.ses_message_id
  end

  test "a rejected advance writes none of the extra attributes" do
    email = fresh_email
    email.apply_event("delivery")

    assert_not email.mark_sent(ses_message_id: "too-late")
    assert_nil email.reload.ses_message_id
  end

  private
    def fresh_email
      Email.create!(project: projects(:acme_default), source: sources(:acme_production),
        from: "hello@acme.com", subject: "Race", html_body: "<p>race</p>")
    end
```

(If the file already has a `private` section, merge `fresh_email` into it instead of adding a second modifier.)

- [ ] **Step 2: Run to verify fail**

Run: `bin/rails test test/models/email/statuses_test.rb`
Expected: FAIL — the stale-copy test regresses `delivered → sent` (compare-then-write on in-memory state), and `mark_sent` doesn't accept keyword arguments (`ArgumentError`).

- [ ] **Step 3: Implement**

`app/models/email/statuses.rb` — replace `mark_sent` and `advance_to`:

```ruby
  def mark_sent(**attributes)
    advance_to("sent", **attributes)
  end
```

```ruby
  private
    # Compare-and-set in the WHERE clause: SQLite has no SELECT ... FOR UPDATE,
    # so the precedence check must live inside the single UPDATE statement.
    # update_all skips validations/callbacks — fine here, new_status only ever
    # comes from the internal maps above.
    def advance_to(new_status, **attributes)
      advanced = self.class.where(id: id, status: lower_precedence_statuses(new_status))
        .update_all(status: new_status, updated_at: Time.current, **attributes) == 1
      reload
      advanced
    end

    def lower_precedence_statuses(new_status)
      new_rank = STATUS_PRECEDENCE.fetch(new_status)
      STATUS_PRECEDENCE.filter_map { |name, rank| name if rank < new_rank }
    end
```

`app/models/email/deliverable.rb` — in `deliver`, replace the two writes:

```ruby
    response = source.ses_client.send_email(destination: destination,
      content: { raw: { data: Email::MimeStore.read(self) } })
    mark_sent(ses_message_id: response.message_id)
```

(Delete the now-stale `update!(ses_message_id: ...)` line and adjust the surrounding comment: duplicate `ses_message_id`s in the crash-retry window remain expected — at-least-once delivery is unchanged.)

- [ ] **Step 4: Run the full suite, verify pass, commit**

Run: `bin/rails test`
Expected: PASS — including the Phase 2 deliverable/job tests, which assert `ses_message_id` after `deliver` and must keep passing untouched.

```bash
bin/rubocop -a
git add -A
git commit -m "fix: row-guarded status advance and single-write mark_sent (phase 3 prerequisite, risk #4)"
```

---

### Task 2 (roadmap 3.1): email_events + webhook_logs migrations and models

**Files:**
- Create: `db/migrate/<ts>_create_email_events.rb`, `db/migrate/<ts>_create_webhook_logs.rb`, `app/models/email_event.rb`, `app/models/webhook_log.rb`
- Modify: `app/models/email.rb` (`has_many :events`), `app/models/source.rb` (`has_many :emails`, `has_many :webhook_logs`), `test/test_helper.rb` (wipe helpers)
- Test: `test/models/email_event_test.rb`, `test/models/webhook_log_test.rb`

**Interfaces:**
- Consumes: `emails.ses_message_id` (Phase 2 populates it), `sources.webhook_token` (Phase 1).
- Produces: `EmailEvent` (`belongs_to :email`; `event_type`, `ses_message_id`, `recipient`, `url`, `user_agent`, `ip`, `payload` json, `occurred_at`; `scope :reverse_chronologically`), `WebhookLog` (`belongs_to :source`, lambda-default `workspace`; `message_type`, `payload` json, enum `status: received/processed/unmatched/failed`, `error`, `processed_at`), `email.events`, `source.emails`, `source.webhook_logs`. `#process`/`#process_later` land in Task 5; this task is schema + shells so Tasks 3–4 can proceed in parallel with clean fixtures.

- [ ] **Step 1: Write the migrations**

```bash
bin/rails generate migration CreateEmailEvents
bin/rails generate migration CreateWebhookLogs
```

```ruby
# db/migrate/<ts>_create_email_events.rb
class CreateEmailEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :email_events do |t|
      t.references :email, null: false, foreign_key: true
      t.string :event_type, null: false
      t.string :ses_message_id
      t.string :recipient
      t.string :url
      t.string :user_agent
      t.string :ip
      t.json :payload, default: {}, null: false
      t.datetime :occurred_at, null: false
      t.timestamps
    end

    add_index :email_events, [ :email_id, :occurred_at ]
  end
end
```

```ruby
# db/migrate/<ts>_create_webhook_logs.rb
class CreateWebhookLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_logs do |t|
      t.references :source, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.string :message_type
      t.json :payload, default: {}, null: false
      t.string :status, default: "received", null: false
      t.string :error
      t.datetime :processed_at
      t.timestamps
    end

    add_index :webhook_logs, [ :source_id, :created_at ]
  end
end
```

Run: `bin/rails db:migrate`
Expected: both tables appear in `db/schema.rb`.

- [ ] **Step 2: Write the failing model tests**

```ruby
# test/models/email_event_test.rb
require "test_helper"

class EmailEventTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    @email = Email.create!(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", subject: "Hi", html_body: "<p>Hi</p>")
  end

  test "requires an event type and an occurrence time" do
    event = @email.events.build

    assert_not event.valid?
    assert event.errors[:event_type].any?
    assert event.errors[:occurred_at].any?
  end

  test "reverse_chronologically orders newest occurrence first" do
    older = @email.events.create!(event_type: "send", occurred_at: 2.hours.ago)
    newer = @email.events.create!(event_type: "delivery", occurred_at: 1.hour.ago)

    assert_equal [ newer, older ], @email.events.reverse_chronologically.to_a
  end

  test "destroying the email destroys its events" do
    @email.events.create!(event_type: "send", occurred_at: Time.current)

    assert_difference -> { EmailEvent.count }, -1 do
      @email.destroy
    end
  end
end
```

```ruby
# test/models/webhook_log_test.rb
require "test_helper"

class WebhookLogTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "workspace defaults from the source" do
    log = sources(:acme_production).webhook_logs.create!(message_type: "Notification", payload: { "Type" => "Notification" })

    assert_equal workspaces(:acme), log.workspace
    assert_equal "received", log.status
  end

  test "status is constrained to the known set" do
    log = sources(:acme_production).webhook_logs.build(payload: {}, status: "bogus")

    assert_not log.valid?
    assert log.errors[:status].any?
  end
end
```

Run: `bin/rails test test/models/email_event_test.rb test/models/webhook_log_test.rb`
Expected: FAIL — `NameError: uninitialized constant EmailEvent` (and `WebhookLog`).

- [ ] **Step 3: Implement models and associations**

```ruby
# app/models/email_event.rb
class EmailEvent < ApplicationRecord
  belongs_to :email

  validates :event_type, presence: true
  validates :occurred_at, presence: true

  scope :reverse_chronologically, -> { order(occurred_at: :desc, id: :desc) }
end
```

```ruby
# app/models/webhook_log.rb
class WebhookLog < ApplicationRecord
  belongs_to :source
  belongs_to :workspace, default: -> { source.workspace }

  enum :status, %w[ received processed unmatched failed ].index_by(&:itself),
    default: "received", validate: true
end
```

```ruby
# app/models/email.rb — add alongside the other has_many lines
  has_many :events, class_name: "EmailEvent", dependent: :destroy
```

```ruby
# app/models/source.rb — add after the belongs_to lines
  has_many :emails
  has_many :webhook_logs, dependent: :destroy
```

- [ ] **Step 4: Extend the wipe helpers**

In `test/test_helper.rb`: add `EmailEvent.delete_all` as the FIRST line of `wipe_send_domain` (events reference emails), and add `WebhookLog.delete_all` to `wipe_workspace_records` immediately BEFORE `Source.delete_all` (logs reference sources).

- [ ] **Step 5: Run the full suite, verify pass, commit**

Run: `bin/rails test`
Expected: PASS

```bash
bin/rubocop -a
git add -A
git commit -m "feat: EmailEvent and WebhookLog models with migrations"
```

---

### Task 3 (roadmap 3.2): Sns::MessageVerifier

**Files:**
- Create: `lib/sns/message_verifier.rb`
- Test: `test/lib/sns/message_verifier_test.rb`

**Interfaces:**
- Consumes: nothing from the app — pure Ruby over OpenSSL/Net::HTTP. `lib/` autoloads (`config.autoload_lib` is already set), so `Sns::MessageVerifier` needs no require.
- Produces: `Sns::MessageVerifier.new(region:, cert_fetcher: nil)` and `#authentic?(message_hash) → true/false` (never raises on malformed input). `cert_fetcher` is a callable `(url) → PEM string` — production default fetches via Net::HTTP and caches in `Rails.cache` for a day; tests inject a lambda serving a locally generated cert. Consumed by Task 6's controller.
- **Testing strategy (risk #1):** real captured payloads would require a live SNS topic; instead the tests generate an RSA keypair + self-signed cert once and sign canonical strings **independently implemented from the AWS spec** inside the test — so a bug in the production canonical-string builder cannot self-confirm. Signed-key sets: Notification → `Message MessageId Subject Timestamp TopicArn Type` (Subject only when non-null); Subscription/UnsubscribeConfirmation → `Message MessageId SubscribeURL Timestamp Token TopicArn Type`. Canonical string is `"key\nvalue\n"` concatenated in that order.

- [ ] **Step 1: Write the failing test**

```ruby
# test/lib/sns/message_verifier_test.rb
require "test_helper"

class Sns::MessageVerifierTest < ActiveSupport::TestCase
  KEY = OpenSSL::PKey::RSA.new(2048)
  CERT = OpenSSL::X509::Certificate.new.tap do |cert|
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=sns.test")
    cert.public_key = KEY.public_key
    cert.serial = 1
    cert.version = 2
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + 86_400
    cert.sign(KEY, OpenSSL::Digest.new("SHA256"))
  end
  CERT_URL = "https://sns.eu-west-1.amazonaws.com/SimpleNotificationService-test.pem".freeze

  test "verifies a SignatureVersion 1 notification" do
    assert verifier.authentic?(signed_notification)
  end

  test "verifies a SignatureVersion 2 notification with SHA256" do
    assert verifier.authentic?(signed_notification("SignatureVersion" => "2"))
  end

  test "verifies a subscription confirmation over its own key set" do
    message = signed_message("Type" => "SubscriptionConfirmation", "Token" => "tok-123",
      "SubscribeURL" => "https://sns.eu-west-1.amazonaws.com/?Action=ConfirmSubscription")

    assert verifier.authentic?(message)
  end

  test "a notification without a Subject still verifies" do
    assert verifier.authentic?(signed_notification("Subject" => nil))
  end

  test "rejects a tampered Message" do
    message = signed_notification
    message["Message"] = "{\"eventType\":\"Tampered\"}"

    assert_not verifier.authentic?(message)
  end

  test "rejects a signature produced by a different key" do
    message = signed_notification
    message["Signature"] = Base64.strict_encode64(
      OpenSSL::PKey::RSA.new(2048).sign(OpenSSL::Digest.new("SHA1"), "whatever"))

    assert_not verifier.authentic?(message)
  end

  test "rejects a cert URL on the wrong host without fetching it" do
    fetched = false
    suspicious = Sns::MessageVerifier.new(region: "eu-west-1",
      cert_fetcher: ->(_url) { fetched = true; CERT.to_pem })
    message = signed_notification("SigningCertURL" => "https://sns.eu-west-1.amazonaws.com.evil.example/cert.pem")

    assert_not suspicious.authentic?(message)
    assert_not fetched, "the pinning check must run before any fetch"
  end

  test "rejects a cert URL for another region, plain http, or a non-pem path" do
    [ "https://sns.us-east-1.amazonaws.com/cert.pem",
      "http://sns.eu-west-1.amazonaws.com/cert.pem",
      "https://sns.eu-west-1.amazonaws.com/cert.txt",
      "not a url" ].each do |url|
      assert_not verifier.authentic?(signed_notification("SigningCertURL" => url)), url
    end
  end

  test "rejects unknown signature versions and unknown message types" do
    assert_not verifier.authentic?(signed_notification("SignatureVersion" => "3"))
    assert_not verifier.authentic?(signed_notification("Type" => "Mystery"))
  end

  test "rejects when the fetched cert is garbage instead of raising" do
    broken = Sns::MessageVerifier.new(region: "eu-west-1", cert_fetcher: ->(_url) { "not a certificate" })

    assert_not broken.authentic?(signed_notification)
  end

  private
    def verifier
      Sns::MessageVerifier.new(region: "eu-west-1", cert_fetcher: ->(url) {
        raise "unexpected cert fetch: #{url}" unless url == CERT_URL
        CERT.to_pem
      })
    end

    def signed_notification(overrides = {})
      signed_message({ "Subject" => "Amazon SES Email Event Notification" }.merge(overrides))
    end

    # Independent implementation of the AWS canonical string, straight from the
    # SNS verification spec — deliberately NOT shared with production code.
    def signed_message(overrides = {})
      message = {
        "Type" => "Notification",
        "MessageId" => "sns-message-1",
        "TopicArn" => "arn:aws:sns:eu-west-1:123456789012:ses-events",
        "Message" => "{\"eventType\":\"Delivery\"}",
        "Timestamp" => "2026-07-01T10:00:00.000Z",
        "SignatureVersion" => "1",
        "SigningCertURL" => CERT_URL
      }.merge(overrides).compact
      message.merge("Signature" => signature_for(message))
    end

    def signature_for(message)
      keys = if message["Type"] == "Notification"
        %w[ Message MessageId Subject Timestamp TopicArn Type ]
      else
        %w[ Message MessageId SubscribeURL Timestamp Token TopicArn Type ]
      end
      digest = message["SignatureVersion"] == "2" ? "SHA256" : "SHA1"
      canonical = keys.filter_map { |key| "#{key}\n#{message[key]}\n" if message[key] }.join
      Base64.strict_encode64(KEY.sign(OpenSSL::Digest.new(digest), canonical))
    end
end
```

- [ ] **Step 2: Run to verify fail**

Run: `bin/rails test test/lib/sns/message_verifier_test.rb`
Expected: FAIL — `NameError: uninitialized constant Sns`

- [ ] **Step 3: Implement**

```ruby
# lib/sns/message_verifier.rb
require "net/http"

module Sns
  # Hand-ported SNS signature verification (risk #1): the aws-sdk gems in our
  # dependency set don't ship Aws::SNS::MessageVerifier. Pinned to the exact
  # per-region SNS cert host; SignatureVersion 1 → SHA1, 2 → SHA256.
  class MessageVerifier
    NOTIFICATION_KEYS = %w[ Message MessageId Subject Timestamp TopicArn Type ].freeze
    SUBSCRIPTION_KEYS = %w[ Message MessageId SubscribeURL Timestamp Token TopicArn Type ].freeze
    DIGESTS = { "1" => "SHA1", "2" => "SHA256" }.freeze

    def initialize(region:, cert_fetcher: nil)
      @region = region
      @cert_fetcher = cert_fetcher || method(:fetch_certificate)
    end

    def authentic?(message)
      digest_name = DIGESTS[message["SignatureVersion"].to_s]
      keys = signed_keys(message["Type"])

      if digest_name.nil? || keys.nil? || !pinned_certificate_url?(message["SigningCertURL"])
        false
      else
        verify(message, keys, digest_name)
      end
    rescue OpenSSL::OpenSSLError
      false
    end

    private
      attr_reader :region, :cert_fetcher

      def signed_keys(type)
        case type
        when "Notification" then NOTIFICATION_KEYS
        when "SubscriptionConfirmation", "UnsubscribeConfirmation" then SUBSCRIPTION_KEYS
        end
      end

      def pinned_certificate_url?(url)
        uri = URI.parse(url.to_s)
        uri.is_a?(URI::HTTPS) && uri.host == "sns.#{region}.amazonaws.com" && uri.path.end_with?(".pem")
      rescue URI::InvalidURIError
        false
      end

      def verify(message, keys, digest_name)
        certificate = OpenSSL::X509::Certificate.new(cert_fetcher.call(message["SigningCertURL"]))
        signature = Base64.decode64(message["Signature"].to_s)
        certificate.public_key.verify(OpenSSL::Digest.new(digest_name), signature, canonical_string(message, keys))
      end

      def canonical_string(message, keys)
        keys.filter_map { |key| "#{key}\n#{message[key]}\n" if message[key] }.join
      end

      def fetch_certificate(url)
        Rails.cache.fetch([ "sns-signing-cert", url ], expires_in: 1.day) do
          Net::HTTP.get(URI.parse(url))
        end
      end
  end
end
```

- [ ] **Step 4: Run the full suite, verify pass, commit**

Run: `bin/rails test`
Expected: PASS

```bash
bin/rubocop -a
git add -A
git commit -m "feat: Sns::MessageVerifier — pinned-host, dual-digest SNS signature verification"
```

---

### Task 4 (roadmap 3.3): Email::SesEvent value object + SNS fixture payloads

**Files:**
- Create: `app/models/email/ses_event.rb`, `test/fixtures/files/sns/{send,delivery,bounce_permanent,bounce_transient,complaint,open,click,reject,delivery_delay}.json`
- Test: `test/models/email/ses_event_test.rb`

**Interfaces:**
- Consumes: a parsed SES event hash (the SNS envelope's `Message` field after `JSON.parse` — NOT the envelope itself).
- Produces: `Email::SesEvent.new(payload)` with `#event_type` (normalized: `send delivery bounce complaint open click reject delivery_delay`, accepting both configuration-set `eventType` and classic `notificationType`), `#ses_message_id`, `#recipients`, `#occurred_at` (event-detail timestamp, falling back to `mail.timestamp`, then `Time.current`), `#bounce?`, `#complaint?`, `#permanent_bounce?`, `#suppresses?` (complaint OR permanent bounce — `Undetermined` counts as NOT permanent), `#url`, `#user_agent`, `#ip`, `#payload`. Consumed by Task 5's `WebhookLog#process`; the fixture files feed Tasks 4–5 and Phase 6's smoke test.

- [ ] **Step 1: Create the fixture payloads**

All nine files share `mail.messageId` `"ses-fixture-message-1"` so ingestion tests can create one matching email.

```json
// test/fixtures/files/sns/send.json
{
  "eventType": "Send",
  "mail": {
    "timestamp": "2026-07-01T09:59:58.000Z",
    "messageId": "ses-fixture-message-1",
    "source": "hello@acme.com",
    "sendingAccountId": "123456789012",
    "destination": ["user@example.com"],
    "headersTruncated": false,
    "tags": { "ses:configuration-set": ["departures"] }
  },
  "send": {}
}
```

```json
// test/fixtures/files/sns/delivery.json
{
  "eventType": "Delivery",
  "mail": {
    "timestamp": "2026-07-01T09:59:58.000Z",
    "messageId": "ses-fixture-message-1",
    "source": "hello@acme.com",
    "sendingAccountId": "123456789012",
    "destination": ["user@example.com"]
  },
  "delivery": {
    "timestamp": "2026-07-01T10:00:02.000Z",
    "processingTimeMillis": 1832,
    "recipients": ["user@example.com"],
    "smtpResponse": "250 2.6.0 message received",
    "reportingMTA": "a8-50.smtp-out.amazonses.com"
  }
}
```

```json
// test/fixtures/files/sns/bounce_permanent.json
{
  "eventType": "Bounce",
  "mail": {
    "timestamp": "2026-07-01T09:59:58.000Z",
    "messageId": "ses-fixture-message-1",
    "source": "hello@acme.com",
    "sendingAccountId": "123456789012",
    "destination": ["bounce@example.com"]
  },
  "bounce": {
    "bounceType": "Permanent",
    "bounceSubType": "General",
    "bouncedRecipients": [
      { "emailAddress": "bounce@example.com", "action": "failed", "status": "5.1.1",
        "diagnosticCode": "smtp; 550 5.1.1 user unknown" }
    ],
    "timestamp": "2026-07-01T10:00:03.000Z",
    "feedbackId": "0100feedback-permanent",
    "reportingMTA": "dns; a8-50.smtp-out.amazonses.com"
  }
}
```

```json
// test/fixtures/files/sns/bounce_transient.json
{
  "eventType": "Bounce",
  "mail": {
    "timestamp": "2026-07-01T09:59:58.000Z",
    "messageId": "ses-fixture-message-1",
    "source": "hello@acme.com",
    "sendingAccountId": "123456789012",
    "destination": ["soft@example.com"]
  },
  "bounce": {
    "bounceType": "Transient",
    "bounceSubType": "MailboxFull",
    "bouncedRecipients": [
      { "emailAddress": "soft@example.com", "action": "failed", "status": "4.2.2",
        "diagnosticCode": "smtp; 452 4.2.2 mailbox full" }
    ],
    "timestamp": "2026-07-01T10:00:03.000Z",
    "feedbackId": "0100feedback-transient"
  }
}
```

```json
// test/fixtures/files/sns/complaint.json
{
  "eventType": "Complaint",
  "mail": {
    "timestamp": "2026-07-01T09:59:58.000Z",
    "messageId": "ses-fixture-message-1",
    "source": "hello@acme.com",
    "sendingAccountId": "123456789012",
    "destination": ["complainer@example.com"]
  },
  "complaint": {
    "complainedRecipients": [ { "emailAddress": "complainer@example.com" } ],
    "timestamp": "2026-07-01T11:00:00.000Z",
    "feedbackId": "0100feedback-complaint",
    "complaintFeedbackType": "abuse",
    "userAgent": "Yahoo!-Mail-Feedback/2.0"
  }
}
```

```json
// test/fixtures/files/sns/open.json
{
  "eventType": "Open",
  "mail": {
    "timestamp": "2026-07-01T09:59:58.000Z",
    "messageId": "ses-fixture-message-1",
    "source": "hello@acme.com",
    "sendingAccountId": "123456789012",
    "destination": ["user@example.com"]
  },
  "open": {
    "timestamp": "2026-07-01T12:00:00.000Z",
    "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5)",
    "ipAddress": "192.0.2.1"
  }
}
```

```json
// test/fixtures/files/sns/click.json
{
  "eventType": "Click",
  "mail": {
    "timestamp": "2026-07-01T09:59:58.000Z",
    "messageId": "ses-fixture-message-1",
    "source": "hello@acme.com",
    "sendingAccountId": "123456789012",
    "destination": ["user@example.com"]
  },
  "click": {
    "timestamp": "2026-07-01T12:05:00.000Z",
    "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5)",
    "ipAddress": "192.0.2.1",
    "link": "https://acme.com/welcome",
    "linkTags": {}
  }
}
```

```json
// test/fixtures/files/sns/reject.json
{
  "eventType": "Reject",
  "mail": {
    "timestamp": "2026-07-01T09:59:58.000Z",
    "messageId": "ses-fixture-message-1",
    "source": "hello@acme.com",
    "sendingAccountId": "123456789012",
    "destination": ["user@example.com"]
  },
  "reject": { "reason": "Bad content" }
}
```

```json
// test/fixtures/files/sns/delivery_delay.json
{
  "eventType": "DeliveryDelay",
  "mail": {
    "timestamp": "2026-07-01T09:59:58.000Z",
    "messageId": "ses-fixture-message-1",
    "source": "hello@acme.com",
    "sendingAccountId": "123456789012",
    "destination": ["user@example.com"]
  },
  "deliveryDelay": {
    "delayType": "MailboxFull",
    "timestamp": "2026-07-01T10:30:00.000Z",
    "expirationTime": "2026-07-02T09:59:58.000Z",
    "delayedRecipients": [
      { "emailAddress": "user@example.com", "status": "4.2.2", "diagnosticCode": "smtp; 452 4.2.2 mailbox full" }
    ]
  }
}
```

- [ ] **Step 2: Write the failing test**

```ruby
# test/models/email/ses_event_test.rb
require "test_helper"

class Email::SesEventTest < ActiveSupport::TestCase
  test "normalizes event types from configuration-set eventType" do
    { "send" => "send", "delivery" => "delivery", "bounce_permanent" => "bounce",
      "complaint" => "complaint", "open" => "open", "click" => "click",
      "reject" => "reject", "delivery_delay" => "delivery_delay" }.each do |fixture, expected|
      assert_equal expected, event(fixture).event_type, fixture
    end
  end

  test "accepts classic notificationType payloads" do
    payload = fixture_payload("bounce_permanent").except("eventType").merge("notificationType" => "Bounce")

    assert_equal "bounce", Email::SesEvent.new(payload).event_type
  end

  test "exposes the ses message id from the mail object" do
    assert_equal "ses-fixture-message-1", event("delivery").ses_message_id
  end

  test "recipients come from the event detail when it names them" do
    assert_equal [ "user@example.com" ], event("delivery").recipients
    assert_equal [ "bounce@example.com" ], event("bounce_permanent").recipients
    assert_equal [ "complainer@example.com" ], event("complaint").recipients
  end

  test "recipients fall back to the mail destination for opens, clicks, sends, and rejects" do
    %w[ send open click reject ].each do |fixture|
      assert_equal [ "user@example.com" ], event(fixture).recipients, fixture
    end
  end

  test "occurred_at prefers the event detail timestamp over the mail timestamp" do
    assert_equal Time.iso8601("2026-07-01T10:00:02.000Z"), event("delivery").occurred_at
    assert_equal Time.iso8601("2026-07-01T09:59:58.000Z"), event("send").occurred_at
  end

  test "occurred_at falls back to now when no timestamp survives" do
    event = Email::SesEvent.new({ "eventType" => "Send" })

    assert_in_delta Time.current, event.occurred_at, 2.seconds
  end

  test "suppresses on complaints and permanent bounces only" do
    assert event("complaint").suppresses?
    assert event("bounce_permanent").suppresses?
    assert_not event("bounce_transient").suppresses?
    assert_not event("delivery").suppresses?
  end

  test "an undetermined bounce is not permanent and never suppresses" do
    payload = fixture_payload("bounce_permanent")
    payload["bounce"]["bounceType"] = "Undetermined"
    event = Email::SesEvent.new(payload)

    assert event.bounce?
    assert_not event.permanent_bounce?
    assert_not event.suppresses?
  end

  test "open and click expose their metadata" do
    open_event = event("open")
    assert_equal "192.0.2.1", open_event.ip
    assert_equal "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5)", open_event.user_agent
    assert_nil open_event.url

    click_event = event("click")
    assert_equal "https://acme.com/welcome", click_event.url
    assert_equal "192.0.2.1", click_event.ip
  end

  private
    def fixture_payload(name)
      JSON.parse(file_fixture("sns/#{name}.json").read)
    end

    def event(name)
      Email::SesEvent.new(fixture_payload(name))
    end
end
```

- [ ] **Step 3: Run to verify fail**

Run: `bin/rails test test/models/email/ses_event_test.rb`
Expected: FAIL — `NameError: uninitialized constant Email::SesEvent`

- [ ] **Step 4: Implement**

```ruby
# app/models/email/ses_event.rb
class Email::SesEvent
  TIMESTAMP_SOURCES = {
    "bounce" => "bounce", "complaint" => "complaint", "delivery" => "delivery",
    "open" => "open", "click" => "click", "delivery_delay" => "deliveryDelay"
  }.freeze

  attr_reader :payload

  def initialize(payload)
    @payload = payload
  end

  def event_type
    raw_event_type.to_s.delete(" ").underscore
  end

  def ses_message_id
    payload.dig("mail", "messageId")
  end

  def recipients
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
  end

  def occurred_at
    Time.iso8601(raw_timestamp)
  rescue ArgumentError, TypeError
    Time.current
  end

  def bounce?
    event_type == "bounce"
  end

  def complaint?
    event_type == "complaint"
  end

  def permanent_bounce?
    bounce? && payload.dig("bounce", "bounceType") == "Permanent"
  end

  def suppresses?
    complaint? || permanent_bounce?
  end

  def url
    payload.dig("click", "link")
  end

  def user_agent
    payload.dig("open", "userAgent") || payload.dig("click", "userAgent")
  end

  def ip
    payload.dig("open", "ipAddress") || payload.dig("click", "ipAddress")
  end

  private
    def raw_event_type
      payload["eventType"] || payload["notificationType"]
    end

    def raw_timestamp
      detail_key = TIMESTAMP_SOURCES[event_type]
      detail_timestamp = detail_key && payload.dig(detail_key, "timestamp")
      detail_timestamp || payload.dig("mail", "timestamp")
    end
end
```

- [ ] **Step 5: Run the full suite, verify pass, commit**

Run: `bin/rails test`
Expected: PASS

```bash
bin/rubocop -a
git add -A
git commit -m "feat: Email::SesEvent value object and SNS event fixture payloads"
```

---

### Task 5 (roadmap 3.5): WebhookLog#process + ProcessSesEventJob + Suppression.record

**Files:**
- Modify: `app/models/webhook_log.rb`, `app/models/suppression.rb`
- Create: `app/jobs/process_ses_event_job.rb`
- Test: `test/models/webhook_log_test.rb` (append), `test/models/suppression_test.rb` (append), `test/jobs/process_ses_event_job_test.rb`

**Interfaces:**
- Consumes: `Email::SesEvent` (Task 4), `email.apply_event` over the row-guarded advance (Task 1), `email.events` / `source.emails` (Task 2), `Suppression`'s unique `(project_id, email)` index + `normalizes :email` (Phase 1).
- Produces: `webhook_log.process` (ALL ingestion logic: SubscriptionConfirmation auto-confirm with pinned https host; Notification → match by `source.emails.find_by(ses_message_id:)`, one `EmailEvent` per recipient, `apply_event`, suppress via `Suppression.record`, `relay_to_endpoints` no-op seam for Phase 5; unmatched → `status: unmatched`; malformed Message JSON → `status: failed` + `error`), `webhook_log.process_later` (enqueues `ProcessSesEventJob`, queue `default`), `Suppression.record(project, address, reason:)` (create-or-reactivate, race-tolerant). Consumed by Task 6's controller and Phase 5's webhook fan-out.

- [ ] **Step 1: Write the failing ingestion tests**

Append to `test/models/webhook_log_test.rb` (inside the class, below the Task 2 tests):

```ruby
  # --- Ingestion (roadmap 3.5) ---

  FIXTURE_MESSAGE_ID = "ses-fixture-message-1".freeze

  test "a delivery notification records an event and advances the email" do
    email = matched_email
    log = process_fixture("delivery")

    event = email.events.sole
    assert_equal "delivery", event.event_type
    assert_equal "user@example.com", event.recipient
    assert_equal Time.iso8601("2026-07-01T10:00:02.000Z"), event.occurred_at
    assert_equal FIXTURE_MESSAGE_ID, event.ses_message_id
    assert_equal "delivered", email.reload.status
    assert log.processed?
    assert log.processed_at.present?
  end

  test "open and click events carry their metadata" do
    email = matched_email
    process_fixture("open")
    process_fixture("click")

    open_event, click_event = email.events.order(:id).last(2)
    assert_equal "192.0.2.1", open_event.ip
    assert open_event.user_agent.present?
    assert_equal "https://acme.com/welcome", click_event.url
    assert_equal "clicked", email.reload.status
  end

  test "a permanent bounce suppresses the recipient" do
    email = matched_email

    assert_difference -> { Suppression.count }, +1 do
      process_fixture("bounce_permanent")
    end

    suppression = Suppression.order(:id).last
    assert_equal "bounce@example.com", suppression.email
    assert_equal "bounce", suppression.reason
    assert_nil suppression.expires_at
    assert_equal projects(:acme_default), suppression.project
    assert_equal "bounced", email.reload.status
  end

  test "a transient bounce never suppresses but still bounces the email" do
    email = matched_email

    assert_no_difference -> { Suppression.count } do
      process_fixture("bounce_transient")
    end

    assert_equal "bounced", email.reload.status
    assert_equal "bounce", email.events.sole.event_type
  end

  test "an undetermined bounce never suppresses" do
    matched_email

    assert_no_difference -> { Suppression.count } do
      process_fixture("bounce_permanent", overrides: { "bounce" => { "bounceType" => "Undetermined" } })
    end
  end

  test "a complaint suppresses with the complaint reason" do
    email = matched_email
    process_fixture("complaint")

    suppression = Suppression.order(:id).last
    assert_equal "complainer@example.com", suppression.email
    assert_equal "complaint", suppression.reason
    assert_equal "complained", email.reload.status
  end

  test "a bounce for an address with an expired suppression reactivates it" do
    matched_email
    lapsed = suppressions(:acme_lapsed)

    assert_no_difference -> { Suppression.count } do
      process_fixture("bounce_permanent",
        overrides: { "bounce" => { "bouncedRecipients" => [ { "emailAddress" => lapsed.email } ] } })
    end

    lapsed.reload
    assert_nil lapsed.expires_at
    assert_equal "bounce", lapsed.reason
  end

  test "out-of-order events never regress status but are still recorded (risk #4)" do
    email = matched_email
    process_fixture("click")
    process_fixture("delivery")

    assert_equal "clicked", email.reload.status
    assert_equal %w[ click delivery ], email.events.order(:id).pluck(:event_type)
  end

  test "a delivery delay records an event without touching status" do
    email = matched_email
    email.mark_sent

    log = process_fixture("delivery_delay")

    assert_equal "sent", email.reload.status
    assert_equal "delivery_delay", email.events.sole.event_type
    assert log.processed?
  end

  test "an event with no matching email marks the log unmatched and keeps the payload" do
    log = process_fixture("delivery")

    assert log.unmatched?
    assert_equal 0, EmailEvent.count
    assert log.payload["Message"].present?
  end

  test "an email on another source with the same ses message id is never matched" do
    Email.create!(project: projects(:globex_default), source: sources(:globex_production),
      from: "hello@globex.com", subject: "Other tenant", html_body: "<p>x</p>",
      status: "sent", ses_message_id: FIXTURE_MESSAGE_ID)

    log = process_fixture("delivery")

    assert log.unmatched?
    assert_equal 0, EmailEvent.count
  end

  test "malformed inner Message JSON fails the log with the parse error" do
    log = sources(:acme_production).webhook_logs.create!(message_type: "Notification",
      payload: { "Type" => "Notification", "Message" => "{not json" })

    log.process

    assert log.failed?
    assert log.error.present?
  end

  test "a subscription confirmation GETs a pinned SubscribeURL and marks the log processed" do
    subscribe_url = "https://sns.eu-west-1.amazonaws.com/?Action=ConfirmSubscription&Token=tok"
    log = sources(:acme_production).webhook_logs.create!(message_type: "SubscriptionConfirmation",
      payload: { "Type" => "SubscriptionConfirmation", "SubscribeURL" => subscribe_url })

    fetched_urls = []
    Net::HTTP.stub :get_response, ->(uri) { fetched_urls << uri.to_s; Net::HTTPOK.new("1.1", "200", "OK") } do
      log.process
    end

    assert_equal [ subscribe_url ], fetched_urls
    assert log.processed?
  end

  test "a subscription confirmation with a foreign SubscribeURL is never fetched" do
    log = sources(:acme_production).webhook_logs.create!(message_type: "SubscriptionConfirmation",
      payload: { "Type" => "SubscriptionConfirmation", "SubscribeURL" => "https://evil.example/confirm" })

    Net::HTTP.stub :get_response, ->(_uri) { flunk "must not fetch a foreign host" } do
      log.process
    end

    assert log.failed?
    assert_includes log.error, "SubscribeURL"
  end

  test "process_later enqueues the job" do
    log = sources(:acme_production).webhook_logs.create!(message_type: "Notification",
      payload: { "Type" => "Notification" })

    assert_enqueued_with(job: ProcessSesEventJob, args: [ log ], queue: "default") do
      log.process_later
    end
  end

  private
    def matched_email
      Email.create!(project: projects(:acme_default), source: sources(:acme_production),
        from: "hello@acme.com", subject: "Tracked", html_body: "<p>hi</p>",
        status: "sent", ses_message_id: FIXTURE_MESSAGE_ID)
    end

    def process_fixture(name, overrides: {})
      message = JSON.parse(file_fixture("sns/#{name}.json").read).deep_merge(overrides)
      log = sources(:acme_production).webhook_logs.create!(message_type: "Notification",
        payload: { "Type" => "Notification", "MessageId" => "sns-#{name}", "Message" => message.to_json })
      log.process
      log
    end
```

Also add `include ActiveJob::TestHelper` directly under the class line (needed by `assert_enqueued_with`).

- [ ] **Step 2: Write the failing Suppression.record tests**

Append to `test/models/suppression_test.rb`:

```ruby
  # --- Phase 3: create-or-reactivate (SNS ingestion) ---

  test "record creates an active suppression with a normalized address" do
    suppression = Suppression.record(projects(:acme_default), "  NEW@Example.COM ", reason: "bounce")

    assert suppression.persisted?
    assert_equal "new@example.com", suppression.email
    assert_equal "bounce", suppression.reason
    assert_nil suppression.expires_at
  end

  test "record reactivates an expired suppression instead of violating the unique index" do
    lapsed = suppressions(:acme_lapsed)

    assert_no_difference -> { Suppression.count } do
      Suppression.record(lapsed.project, lapsed.email, reason: "complaint")
    end

    lapsed.reload
    assert_nil lapsed.expires_at
    assert_equal "complaint", lapsed.reason
  end
```

- [ ] **Step 3: Write the failing job test**

```ruby
# test/jobs/process_ses_event_job_test.rb
require "test_helper"

class ProcessSesEventJobTest < ActiveJob::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "performing the job processes the log" do
    log = sources(:acme_production).webhook_logs.create!(message_type: "Notification",
      payload: { "Type" => "Notification", "Message" => { "eventType" => "Delivery",
        "mail" => { "messageId" => "no-such-message" } }.to_json })

    perform_enqueued_jobs do
      ProcessSesEventJob.perform_later(log)
    end

    assert log.reload.unmatched?
  end
end
```

- [ ] **Step 4: Run to verify fail**

Run: `bin/rails test test/models/webhook_log_test.rb test/models/suppression_test.rb test/jobs/process_ses_event_job_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'process'`, `undefined method 'record'`, `NameError: uninitialized constant ProcessSesEventJob`.

- [ ] **Step 5: Implement**

```ruby
# app/models/webhook_log.rb
class WebhookLog < ApplicationRecord
  SUBSCRIBE_HOST_PATTERN = /\Asns\.[a-z0-9-]+\.amazonaws\.com\z/

  belongs_to :source
  belongs_to :workspace, default: -> { source.workspace }

  enum :status, %w[ received processed unmatched failed ].index_by(&:itself),
    default: "received", validate: true

  def process
    case message_type
    when "SubscriptionConfirmation"
      confirm_subscription
    when "Notification"
      ingest_notification
    else
      update!(status: "processed", processed_at: Time.current)
    end
  end

  def process_later
    ProcessSesEventJob.perform_later(self)
  end

  private
    def confirm_subscription
      if confirmable_subscribe_url?
        Net::HTTP.get_response(URI.parse(payload["SubscribeURL"]))
        update!(status: "processed", processed_at: Time.current)
      else
        update!(status: "failed", error: "SubscribeURL is not a pinned SNS https endpoint")
      end
    end

    def confirmable_subscribe_url?
      uri = URI.parse(payload["SubscribeURL"].to_s)
      uri.is_a?(URI::HTTPS) && uri.host.to_s.match?(SUBSCRIBE_HOST_PATTERN)
    rescue URI::InvalidURIError
      false
    end

    def ingest_notification
      event = Email::SesEvent.new(JSON.parse(payload["Message"].to_s))
      email = source.emails.find_by(ses_message_id: event.ses_message_id)

      if email
        record_events(email, event)
        email.apply_event(event.event_type)
        suppress_recipients(email, event)
        relay_to_endpoints(email, event)
        update!(status: "processed", processed_at: Time.current)
      else
        update!(status: "unmatched", processed_at: Time.current)
      end
    rescue JSON::ParserError => error
      update!(status: "failed", error: error.message)
    end

    def record_events(email, event)
      addresses = event.recipients.presence || [ nil ]
      addresses.each do |address|
        email.events.create!(event_type: event.event_type, ses_message_id: event.ses_message_id,
          recipient: address, url: event.url, user_agent: event.user_agent, ip: event.ip,
          payload: event.payload, occurred_at: event.occurred_at)
      end
    end

    def suppress_recipients(email, event)
      if event.suppresses?
        event.recipients.each do |address|
          Suppression.record(email.project, address, reason: event.event_type)
        end
      end
    end

    def relay_to_endpoints(email, event)
      # Outbound webhook fan-out fills this seam in Phase 5 (WebhookEndpoint).
    end
end
```

```ruby
# app/models/suppression.rb — extend the existing class << self block
  class << self
    def covers?(project, addresses)
      normalized = Array(addresses).map { |address| address.to_s.strip.downcase }
      active.where(project: project, email: normalized).pluck(:email)
    end

    # Create-or-reactivate: the unique (project_id, email) index also holds
    # expired rows, so a bounce for a lapsed address must revive the row.
    def record(project, address, reason:)
      suppression = find_or_initialize_by(project: project, email: address)
      suppression.update!(reason: reason, expires_at: nil)
      suppression
    rescue ActiveRecord::RecordNotUnique
      # A concurrent worker inserted between our lookup and insert — the row
      # now exists, so the retry takes the update path.
      retry
    end
  end
```

```ruby
# app/jobs/process_ses_event_job.rb
class ProcessSesEventJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError

  def perform(webhook_log)
    webhook_log.process
  end
end
```

Add `require "net/http"` is NOT needed in the model — `lib/sns/message_verifier.rb` already requires it and Zeitwerk loads nothing lazily at that point in tests; if `NameError: uninitialized constant Net::HTTP` appears anyway, add `require "net/http"` to `config/application.rb` below the Bundler require.

- [ ] **Step 6: Run the full suite, verify pass**

Run: `bin/rails test`
Expected: PASS

- [ ] **Step 7: Roadmap coverage guard — expired suppressions must not block sends**

Confirm Phase 1 already covers it: `rg -n "lapsed" test/models/email_submission_test.rb test/models/suppression_test.rb`. If NO hit exists in `email_submission_test.rb`, append there:

```ruby
  test "an address whose suppression has expired can be sent to again" do
    submission = delivery_submission(to: [ suppressions(:acme_lapsed).email ])

    assert submission.save
  end
```

- [ ] **Step 8: Commit**

```bash
bin/rubocop -a
git add -A
git commit -m "feat: WebhookLog#process ingestion — events, status advance, suppressions, confirm seam"
```

---

### Task 6 (roadmap 3.4): inbound route + Webhooks::SesController

**Files:**
- Create: `app/controllers/webhooks/ses_controller.rb`
- Modify: `config/routes.rb`
- Test: `test/controllers/webhooks/ses_controller_test.rb`

**Interfaces:**
- Consumes: `Source.find_by(webhook_token:)` (Phase 1), `Sns::MessageVerifier` (Task 3), `webhook_log.process_later` (Task 5), the ActiveJob workspace extension (Phase 0 — `Current.workspace` is set from the source before enqueueing so the job carries tenant context).
- Produces: `POST /api/webhooks/ses/:webhook_token` → 404 unknown token (no log), 400 malformed JSON, 429 past 120/min/token, 403 bad signature (log kept, `failed`), 200 verified (log `received`, job enqueued). Thin: the action is create-log → verify → enqueue, nothing else. This is the URL you paste into the SNS topic subscription per source.
- **Roadmap deviation (recorded):** the master plan words auto-confirm as a controller step; here `SubscriptionConfirmation` flows through the same `process_later` path and `WebhookLog#process` performs the confirm (Task 5). Rationale: keeps the outbound `SubscribeURL` GET out of the request cycle and the controller logic-free; SNS retries unconfirmed subscriptions, so asynchronous confirmation is safe.

- [ ] **Step 1: Add the route**

```ruby
# config/routes.rb — add below the api namespace block
  post "api/webhooks/ses/:webhook_token", to: "webhooks/ses#create", as: :ses_webhooks
```

- [ ] **Step 2: Write the failing controller test**

```ruby
# test/controllers/webhooks/ses_controller_test.rb
require "test_helper"

class Webhooks::SesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  class FakeVerifier
    def initialize(authentic)
      @authentic = authentic
    end

    def authentic?(_message)
      @authentic
    end
  end

  setup do
    Rails.cache.clear
  end

  def notification_payload(**overrides)
    { "Type" => "Notification", "MessageId" => "sns-1", "TopicArn" => "arn:aws:sns:eu-west-1:1:t",
      "Message" => { "eventType" => "Delivery", "mail" => { "messageId" => "m-1" } }.to_json,
      "Timestamp" => "2026-07-01T10:00:00.000Z", "SignatureVersion" => "1",
      "Signature" => "sig", "SigningCertURL" => "https://sns.eu-west-1.amazonaws.com/c.pem" }.merge(overrides)
  end

  def post_webhook(token: sources(:acme_production).webhook_token, body: notification_payload.to_json, authentic: true)
    Sns::MessageVerifier.stub :new, FakeVerifier.new(authentic) do
      post "/api/webhooks/ses/#{token}", params: body, headers: { "Content-Type" => "text/plain" }
    end
  end

  test "an unknown webhook token is not found and creates no log" do
    assert_no_difference -> { WebhookLog.count } do
      post_webhook(token: "no-such-token")
    end

    assert_response :not_found
  end

  test "a verified notification logs the payload and enqueues processing" do
    log = nil
    assert_difference -> { WebhookLog.count }, +1 do
      assert_enqueued_with(job: ProcessSesEventJob) do
        post_webhook
      end
    end

    assert_response :ok
    log = WebhookLog.order(:id).last
    assert_equal sources(:acme_production), log.source
    assert_equal workspaces(:acme), log.workspace
    assert_equal "Notification", log.message_type
    assert_equal "received", log.status
    assert log.payload["Message"].present?
  end

  test "a bad signature keeps the log as failed and responds forbidden" do
    assert_difference -> { WebhookLog.count }, +1 do
      assert_no_enqueued_jobs only: ProcessSesEventJob do
        post_webhook(authentic: false)
      end
    end

    assert_response :forbidden
    log = WebhookLog.order(:id).last
    assert log.failed?
    assert_includes log.error, "signature"
  end

  test "a body that is not JSON is a bad request and creates no log" do
    assert_no_difference -> { WebhookLog.count } do
      post_webhook(body: "not json at all")
    end

    assert_response :bad_request
  end

  test "requests beyond 120 per minute per token are rejected" do
    Sns::MessageVerifier.stub :new, FakeVerifier.new(true) do
      120.times do
        post "/api/webhooks/ses/#{sources(:acme_production).webhook_token}",
          params: notification_payload.to_json, headers: { "Content-Type" => "text/plain" }
        assert_response :ok
      end

      post "/api/webhooks/ses/#{sources(:acme_production).webhook_token}",
        params: notification_payload.to_json, headers: { "Content-Type" => "text/plain" }
      assert_response :too_many_requests
    end
  end
end
```

- [ ] **Step 3: Run to verify fail**

Run: `bin/rails test test/controllers/webhooks/ses_controller_test.rb`
Expected: FAIL — routing error, then `NameError: uninitialized constant Webhooks::SesController`.

- [ ] **Step 4: Implement**

```ruby
# app/controllers/webhooks/ses_controller.rb
class Webhooks::SesController < ActionController::API
  # Declared first so floods are rejected before any database work.
  rate_limit to: 120, within: 1.minute, by: -> { params[:webhook_token] }, scope: :sns_webhook,
    with: -> { head :too_many_requests }

  before_action :set_source
  before_action :set_payload

  def create
    webhook_log = @source.webhook_logs.create!(message_type: @payload["Type"], payload: @payload)

    if verifier.authentic?(@payload)
      webhook_log.process_later
      head :ok
    else
      webhook_log.update!(status: "failed", error: "invalid SNS signature")
      head :forbidden
    end
  end

  private
    def set_source
      @source = Source.find_by(webhook_token: params[:webhook_token])

      if @source
        Current.workspace = @source.workspace
      else
        head :not_found
      end
    end

    # SNS posts JSON with Content-Type text/plain, so Rails never fills params.
    def set_payload
      @payload = JSON.parse(request.body.read)
    rescue JSON::ParserError
      head :bad_request
    end

    def verifier
      Sns::MessageVerifier.new(region: @source.region)
    end
end
```

- [ ] **Step 5: Run the full suite, verify pass, commit**

Run: `bin/rails test`
Expected: PASS

```bash
bin/rubocop -a
git add -A
git commit -m "feat: inbound SNS webhook endpoint — verify, log, enqueue"
```

---

### Task 7 (roadmap 3.6): Broadcastable

**Files:**
- Create: `app/models/concerns/broadcastable.rb`
- Modify: `app/models/email.rb` (include), `app/models/email/statuses.rb` (`advance_to` broadcasts on success)
- Test: `test/models/broadcastable_test.rb`

**Interfaces:**
- Consumes: turbo-rails `broadcast_refresh_to` (Solid Cable), `advance_to` (Task 1).
- Produces: every successful status advance (from `deliver` OR from SNS ingestion) broadcasts `<turbo-stream action="refresh">` to the `[project, :activity]` stream. Phase 4's activity view subscribes with `turbo_stream_from [Current.project, :activity]` and re-renders on morph. **Design notes:** the broadcast is called explicitly from `advance_to` because `update_all` skips callbacks — an `after_update_commit` would never fire; the synchronous `broadcast_refresh_to` is used (NOT `broadcast_refresh_later_to`) because a refresh renders no templates — it's one cheap Action Cable write — and the `_later` variant's thread-debouncer is flaky under Minitest.

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/broadcastable_test.rb
require "test_helper"

class BroadcastableTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  setup do
    Current.session = sessions(:owner)
    @email = Email.create!(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", subject: "Live", html_body: "<p>hi</p>")
  end

  test "a successful status advance broadcasts a refresh to the project activity stream" do
    streams = capture_turbo_stream_broadcasts([ @email.project, :activity ]) do
      @email.apply_event("delivery")
    end

    assert_equal "refresh", streams.sole["action"]
  end

  test "a rejected advance broadcasts nothing" do
    @email.apply_event("delivery")

    streams = capture_turbo_stream_broadcasts([ @email.project, :activity ]) do
      @email.mark_sending
    end

    assert_empty streams
  end
end
```

- [ ] **Step 2: Run to verify fail**

Run: `bin/rails test test/models/broadcastable_test.rb`
Expected: FAIL — no broadcast captured (`streams` empty → `sole` raises).

- [ ] **Step 3: Implement**

```ruby
# app/models/concerns/broadcastable.rb
# Live-activity broadcasting for project-owned records: a refresh stream
# action on [project, :activity], morphed by any subscribed dashboard view.
module Broadcastable
  extend ActiveSupport::Concern

  def broadcast_activity
    broadcast_refresh_to(project, :activity)
  end
end
```

```ruby
# app/models/email.rb — extend the include line
  include Statuses, Deliverable, Broadcastable
```

```ruby
# app/models/email/statuses.rb — advance_to gains the broadcast call
    def advance_to(new_status, **attributes)
      advanced = self.class.where(id: id, status: lower_precedence_statuses(new_status))
        .update_all(status: new_status, updated_at: Time.current, **attributes) == 1
      reload

      if advanced
        broadcast_activity
      end

      advanced
    end
```

- [ ] **Step 4: Run the full suite, verify pass, commit**

Run: `bin/rails test`
Expected: PASS (the Task 5 ingestion tests now also broadcast — the test adapter absorbs them silently).

```bash
bin/rubocop -a
git add -A
git commit -m "feat: Broadcastable — activity refresh broadcast on every status advance"
```

---

### Task 8: Phase wrap-up

**Files:**
- Modify: `docs/plans/departures-execution-plan.md` (Phase 3 status line), `README.md` (webhook endpoint note)

- [ ] **Step 1: Full verification**

```bash
bin/rubocop
bin/rails test
rg "def \w+!" app/
```

Expected: 0 offenses, all tests pass, the bang scan finds nothing (Phase 3 defines no bang methods).

- [ ] **Step 2: Roadmap test-list audit**

Confirm each required Phase 3 test exists and passes: fixture payloads for every event type (Task 4 files, exercised in Tasks 4–5) ✓; bad signature 403 (Task 6) ✓; soft bounce no-suppress (Task 5) ✓; expired suppression doesn't block sends (Task 5 Step 7) ✓; out-of-order events don't regress status — risk #4 (Tasks 1 & 5) ✓; unmatched-event policy (Task 5) ✓.

- [ ] **Step 3: Manual smoke (no AWS touched)**

```bash
bin/rails runner '
  source = Source.first
  Current.workspace = source.workspace

  email = Email.create!(project: source.project, source: source, from: "hello@example.com",
    subject: "Smoke", html_body: "<p>hi</p>", status: "sent", ses_message_id: "smoke-ses-1")

  message = JSON.parse(Rails.root.join("test/fixtures/files/sns/bounce_permanent.json").read)
  message["mail"]["messageId"] = "smoke-ses-1"

  log = source.webhook_logs.create!(message_type: "Notification",
    payload: { "Type" => "Notification", "Message" => message.to_json })
  log.process

  puts({ log: log.status, email: email.reload.status,
         events: email.events.pluck(:event_type),
         suppressed: Suppression.order(:id).last&.email }.inspect)
'
```

Expected: `log: "processed"`, `email: "bounced"`, `events: ["bounce"]`, `suppressed: "bounce@example.com"`. Clean up: `bin/rails runner 'Suppression.where(email: "bounce@example.com").delete_all; Email.where(ses_message_id: "smoke-ses-1").destroy_all; WebhookLog.delete_all'`

- [ ] **Step 4: Docs + commit**

In `docs/plans/departures-execution-plan.md`, add under the `### Phase 3` heading:
`Detailed plan: **docs/plans/phase-3-sns-ingestion-plan.md** (complete).`
In README, document the per-source SNS subscription URL (`POST /api/webhooks/ses/:webhook_token`), the event → status flow, and the suppression policy (complaints + permanent bounces, expiry-aware).

```bash
git add -A
git commit -m "chore: phase 3 wrap-up — rubocop, smoke, docs"
```

---

## Verification (phase-level)

- `bin/rails test` green; `bin/rubocop` clean.
- Roadmap Phase 3 test list fully covered (Task 8 Step 2 audit).
- Phase 2 → Phase 3 prerequisite closed: `advance_to` is a row-guarded write; `ses_message_id` folds into `mark_sent` (Task 1).
- Standards: `ProcessSesEventJob` is 3 lines + discard policy; `Webhooks::SesController#create` is log → verify → enqueue with zero ingestion logic; no bang methods; no custom routes beyond the single inbound webhook POST (external URL shape is fixed by what we give SNS).
- Security posture: signing-cert host pinned per source region, `SubscribeURL` pinned to `sns.*.amazonaws.com` https before any fetch, unknown tokens 404 without a log row, cross-source `ses_message_id` collisions unmatched.
- Seams left for later phases: `WebhookLog#relay_to_endpoints` (Phase 5 outbound webhooks), `[project, :activity]` stream name + `EmailEvent` rows + `reverse_chronologically` (Phase 4 dashboard), `WebhookLog.prune` / `EmailEvent` retention (Phase 6 — logs carry `created_at` and the `(source_id, created_at)` index for batched deletes).
- Before starting Phase 4: author `docs/plans/phase-4-dashboard-plan.md`; note that Phase 4's activity feed should read through `Email` scopes + `email.events`, subscribe via `turbo_stream_from [Current.project, :activity]`, and that every status change already broadcasts a refresh.

## Final-review outcomes (recorded post-execution)

- **Two plan defects fixed in the final-review wave (`5b40a47`) — do not copy these patterns into future plans:** (1) this plan's `fetch_certificate` snippet (`Rails.cache.fetch { Net::HTTP.get(...) }`) cached non-200 bodies, poisoning the cert cache for a day and silently 403-ing a region's events; production code now uses `get_response`, validates the PEM, caches only on success, and raises `Sns::MessageVerifier::CertificateFetchError < IOError` (→ controller 503 → SNS retries). (2) The plan gave `ProcessSesEventJob` only `discard_on` — but the ingestion design (transactional rollback + `received?` guard) assumes retries Solid Queue never does by itself; the job now has `retry_on` for the networking family, 5 attempts, terminal → log `failed`.
- Other fixes in the wave: non-object-but-valid JSON body → 400 (was 500); `broadcast_activity` wrapped in `ActiveRecord.after_all_transactions_commit` (a pre-commit broadcast could reach subscribers with no post-commit rebroadcast); `relay_to_endpoints` seam comment pins enqueue-only; explicit `require "base64"`.
- Adjudicated deviations vs this plan's snippets: `advance_to` reloads only on the rejected path (unconditional reload broke Phase 2's injected SES stub — success mirrors via `assign_attributes` + `changes_applied`); Task 5 gained a `received?` idempotency guard + one ingestion transaction; the webhook controller rescues cert-fetch networking errors → 503.
- **Deferred to Phase 4 (list as prerequisites-or-first-touch in its plan):** controller-rescue nil-log guard; `Email::SesEvent#recipients` `[null]`-element hardening; `changes_applied` clears all dirty attrs / stale in-memory `updated_at` in `advance_to`; stale `Deliverable#deliver` comment about reload; `Suppression.covers?` vs `normalizes` drift (`normalize_value_for`).
- Accepted policies: cross-log SNS redelivery may duplicate `EmailEvent` rows (no cross-log dedup); `Suppression.record` retry-in-transaction is fine on SQLite (Postgres-hostile — revisit only if the adapter ever changes); rate limit keyed by attacker-chosen token costs one indexed lookup per unknown-token request.

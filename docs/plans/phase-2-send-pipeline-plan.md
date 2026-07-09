# Phase 2 — Send Pipeline: MIME, Storage, SES Job — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Accepted emails actually get delivered: `Email::MimeBuilder` renders the full MIME message with the `mail` gem, `Email::MimeStore` persists the `.eml` to disk, and `Email::Deliverable` + `SendEmailJob` send it through SESv2 with retry/failure semantics — enqueued automatically from `EmailSubmission#save`.

**Architecture:** Everything follows `docs/patterns-and-best-practices.md`: plain Ruby classes in `app/models/email/` (presenter philosophy §3.4), an `Email::Deliverable` concern holding all delivery logic, an ultra-thin 3-line job (§4.4), and the Phase 0 ActiveJob extension restoring `Current.workspace` in jobs (§4.5). **MIME is built at submission time, not deliver time** — attachment base64 content exists only in-memory on `EmailSubmission` (the `email_attachments` table stores metadata only), so the `.eml` is written inside `create_email`'s transaction and the job later reads it from disk.

**Tech Stack:** Rails 8.1, `mail` gem 2.9 (already loaded via Action Mailer — no new gems), `aws-sdk-sesv2`, Solid Queue.

## Global Constraints

- Default integer primary keys. No new gems.
- Bang rule (§5.1): `mark_sending`, `mark_sent`, `mark_failed(reason)` — **no bangs** (the master roadmap's `mark_sent!` spelling is overridden, same correction as Phase 1).
- MIME id header is `X-Departures-Id` (already in `EmailSubmission::RESERVED_HEADERS`, so users can't collide with it).
- `.eml` files live at `{root}/{project_id}/{public_id}.eml`; `emails.mime_path` stores the **relative** path (`"{project_id}/{public_id}.eml"`), resolved against `Email::MimeStore.root` at read time. Root defaults to `storage/emails` (Kamal volume, gitignored), test env overrides to `tmp/storage/emails`.
- **Bcc never appears in the MIME** — `Mail#encoded` includes any Bcc field you set (Mail only strips it during its own SMTP delivery, which we don't use). Bcc recipients receive because `Deliverable` passes an explicit `destination: { to_addresses:, cc_addresses:, bcc_addresses: }` to SESv2 `send_email` alongside `content: { raw: }`; SES delivers to the Destination regardless of headers. Task 5's spike confirms this against the sandbox.
- **Retry-guard correction to the roadmap:** `deliver` guards `queued? || sending?`, NOT `queued?` alone. A retried job attempt arrives with status already `sending` (attempt 1 called `mark_sending` before the SES call raised); a `queued?`-only guard would silently no-op every retry and the email would never send. `Email::Statuses#advance_to` is strictly monotonic, so `sent`/`failed`/event-advanced emails still can't regress or double-send.
- `content.raw.data` takes the **raw eml string** — the AWS SDK base64-encodes on the wire; never pre-encode. The SESv2 response field is `response.message_id`.
- SES is only ever touched through `source.ses_client` (memoized + `attr_writer`-injectable). Unit tests inject `Aws::SESV2::Client.new(stub_responses: true)`; job tests must instead stub the constructor (`Aws::SESV2::Client.stub :new, stubbed`) because GlobalID deserialization gives the job a fresh `Source` instance that has lost the injected stub. No webmock.
- **Parallel-test filesystem safety:** tests run with `parallelize(workers: :number_of_processors)` sharing one disk. Fixture emails share `public_id` across workers → colliding `.eml` paths. Every test that writes through `MimeStore` MUST use a freshly created email (random `public_id`), never `emails(:acme_welcome)`.
- `Current.session = sessions(:owner)` in every model-test setup (gotcha §7.3.1).
- Style rules from patterns §5.1 apply to all code: expanded conditionals (a guard is OK only at the start of a non-trivial body), class methods → public (`initialize` first) → private, private methods indented and in invocation order.
- Every task ends with `bin/rails test` green and a commit. Run `bin/rubocop -a` before each commit.

**Task prelude (all tasks):** re-read patterns doc §3.4 (plain Ruby classes in `app/models/`), Part 2 (concerns) and §5.1 (style). Task 3 additionally: §4.4–4.5 (`_now/_later`, ActiveJob workspace extension, `config/initializers/active_job.rb`). Task 4 additionally: re-read `app/models/email_submission.rb` in full. No task in this phase touches views.

---

### Task 1 (roadmap 2.1): Email::MimeBuilder

**Files:**
- Create: `app/models/email/mime_builder.rb`
- Test: `test/models/email/mime_builder_test.rb`

**Interfaces:**
- Consumes: `Email#from/subject/html_body/text_body/headers/public_id` and `email.recipients` kinds (Phase 1). Attachment content comes from the caller — it is NOT on the Email record.
- Produces: `Email::MimeBuilder.new(email, attachments: [ { filename:, content_type:, content: <base64> } ])` (attachments kwarg defaults to `[]`; same symbolized-hash shape `EmailSubmission#attachments=` already normalizes), `#to_eml → String`. Consumed by Task 4 (`EmailSubmission#create_email`) and Phase 4's resend.
- **Mail-gem gotcha this task exists to tame:** with html + text + attachments, naive `Mail.new { text_part; html_part; add_file }` yields a *flat* `multipart/mixed` with three sibling parts (clients then render the text version). The `multipart/alternative` part must be built explicitly and added first. We always `add_part` the body (never set `message.body` directly), so the top level is deterministically `multipart/mixed` and tests can assert `mail.parts.first` regardless of attachment count.

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/email/mime_builder_test.rb
require "test_helper"

class Email::MimeBuilderTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    @email = Email.create!(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", subject: "Welcome", html_body: "<p>Hi</p>", text_body: "Hi",
      headers: { "X-Campaign" => "onboarding" })
    @email.recipients.create!(kind: "to", address: "user@example.com")
    @email.recipients.create!(kind: "cc", address: "copy@example.com")
    @email.recipients.create!(kind: "bcc", address: "hidden@example.com")
  end

  test "to_eml returns a parseable MIME string with envelope headers" do
    mail = parsed

    assert_equal [ "hello@acme.com" ], mail.from
    assert_equal [ "user@example.com" ], mail.to
    assert_equal [ "copy@example.com" ], mail.cc
    assert_equal "Welcome", mail.subject
  end

  test "bcc recipients never appear anywhere in the MIME" do
    eml = Email::MimeBuilder.new(@email).to_eml

    assert_not_includes eml, "hidden@example.com"
    assert_not_includes eml.downcase, "\nbcc:"
  end

  test "identification headers are set" do
    mail = parsed

    assert_equal @email.public_id, mail.header["X-Departures-Id"].value
    assert_equal "#{@email.public_id}@acme.com", mail.message_id
  end

  test "custom headers pass through" do
    assert_equal "onboarding", parsed.header["X-Campaign"].value
  end

  test "html and text nest as multipart/alternative with text before html" do
    alternative = parsed.parts.first

    assert alternative.content_type.start_with?("multipart/alternative")
    assert_equal "text/plain", alternative.parts.first.mime_type
    assert_equal "text/html", alternative.parts.second.mime_type
    assert_equal "Hi", alternative.parts.first.decoded
    assert_equal "<p>Hi</p>", alternative.parts.second.decoded
  end

  test "html-only email carries a single html part" do
    @email.update!(text_body: nil)

    mail = parsed
    assert_equal "text/html", mail.parts.first.mime_type
    assert(mail.parts.none? { |part| part.mime_type == "text/plain" })
  end

  test "text-only email carries a single text part" do
    @email.update!(html_body: nil)

    assert_equal "text/plain", parsed.parts.first.mime_type
  end

  test "attachments encode and round-trip, nested beside the alternative part" do
    content = Base64.strict_encode64("Hello PDF bytes")
    mail = parsed(attachments: [ { filename: "report.pdf", content_type: "application/pdf", content: content } ])

    attachment = mail.attachments["report.pdf"]
    assert_equal "application/pdf", attachment.mime_type
    assert_equal "Hello PDF bytes", attachment.decoded
    assert mail.parts.first.content_type.start_with?("multipart/alternative"),
      "alternative part must stay nested as the first sibling of the attachment"
  end

  test "attachments without a content type fall back to octet-stream" do
    content = Base64.strict_encode64("bytes")
    mail = parsed(attachments: [ { filename: "blob.bin", content_type: nil, content: content } ])

    assert_equal "application/octet-stream", mail.attachments["blob.bin"].mime_type
  end

  private
    def parsed(attachments: [])
      Mail.read_from_string(Email::MimeBuilder.new(@email, attachments: attachments).to_eml)
    end
end
```

- [ ] **Step 2: Run to verify fail**

Run: `bin/rails test test/models/email/mime_builder_test.rb`
Expected: FAIL — `NameError: uninitialized constant Email::MimeBuilder`

- [ ] **Step 3: Implement**

```ruby
# app/models/email/mime_builder.rb
class Email::MimeBuilder
  attr_reader :email, :attachments

  def initialize(email, attachments: [])
    @email = email
    @attachments = attachments
  end

  def to_eml
    mail.encoded
  end

  private
    def mail
      @mail ||= Mail.new.tap do |message|
        message.from = email.from
        message.to = addresses_for("to")

        if addresses_for("cc").any?
          message.cc = addresses_for("cc")
        end

        message.subject = email.subject
        message.message_id = "#{email.public_id}@#{from_domain}"
        message.header["X-Departures-Id"] = email.public_id
        email.headers.each { |name, value| message.header[name] = value }
        add_body(message)
        add_attachments(message)
      end
    end

    def addresses_for(kind)
      email.recipients.where(kind: kind).order(:id).pluck(:address)
    end

    def from_domain
      email.from.to_s.split("@").last
    end

    def add_body(message)
      if email.html_body.present? && email.text_body.present?
        message.add_part(alternative_part)
      elsif email.html_body.present?
        message.add_part(html_part)
      else
        message.add_part(text_part)
      end
    end

    def alternative_part
      Mail::Part.new(content_type: "multipart/alternative").tap do |alternative|
        alternative.add_part(text_part)
        alternative.add_part(html_part)
      end
    end

    def text_part
      Mail::Part.new(body: email.text_body, content_type: "text/plain; charset=UTF-8")
    end

    def html_part
      Mail::Part.new(body: email.html_body, content_type: "text/html; charset=UTF-8")
    end

    def add_attachments(message)
      attachments.each do |attachment|
        message.attachments[attachment[:filename]] = {
          mime_type: attachment[:content_type].presence || "application/octet-stream",
          content: Base64.decode64(attachment[:content].to_s) }
      end
    end
end
```

(Bcc is deliberately never set on the Mail object — see Global Constraints. `message_id` is deterministic, `{public_id}@{from_domain}`, so a stored `.eml` is greppable back to its row; the mail gem adds the angle brackets.)

- [ ] **Step 4: Run, verify pass, commit**

Run: `bin/rails test test/models/email/mime_builder_test.rb`
Expected: PASS. If the multipart-structure assertions fail, inspect `puts Email::MimeBuilder.new(@email).to_eml` — the fix belongs in `add_body`/`alternative_part` (explicit nesting), never in loosening the test.

Run: `bin/rails test`
Expected: PASS

```bash
bin/rubocop -a
git add -A
git commit -m "feat: Email::MimeBuilder — nested multipart MIME with attachments and X-Departures-Id"
```

---

### Task 2 (roadmap 2.2): Email::MimeStore

**Files:**
- Create: `app/models/email/mime_store.rb`
- Modify: `config/environments/test.rb` (mime store root under `tmp/`)
- Test: `test/models/email/mime_store_test.rb`

**Interfaces:**
- Consumes: `emails.mime_path` (string) and `emails.mime_size` (integer) columns — created in Phase 1 as seams for exactly this.
- Produces: `Email::MimeStore.write(email, eml)` (writes the file AND calls `email.update!(mime_path:, mime_size:)` — the single place the directive "path/size stored on Email" lives), `Email::MimeStore.read(email) → String` (binary), `Email::MimeStore.delete(email)` (tolerates missing file/blank path — Phase 6 pruning and orphan sweeps rely on this), `Email::MimeStore.root → Pathname`. Consumed by Task 3 (`deliver` reads), Task 4 (submission writes), Phase 4 (`raw` download), Phase 6 (pruning deletes).

- [ ] **Step 1: Configure the test root**

```ruby
# config/environments/test.rb (add before the final `end`)

  # Keep MimeStore .eml files out of storage/ (sqlite lives there) and inside tmp/.
  config.x.mime_store_root = Rails.root.join("tmp", "storage", "emails")
```

- [ ] **Step 2: Write the failing test**

```ruby
# test/models/email/mime_store_test.rb
require "test_helper"

class Email::MimeStoreTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    # Freshly created email (random public_id) — parallel test workers share the
    # filesystem, so fixture emails' fixed public_ids would collide across workers.
    @email = Email.create!(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", subject: "Hi", html_body: "<p>Hi</p>")
  end

  teardown do
    Email::MimeStore.delete(@email)
  end

  test "root points at tmp storage in the test env" do
    assert_equal Rails.root.join("tmp", "storage", "emails"), Email::MimeStore.root
  end

  test "write stores the file and records the relative path and byte size" do
    eml = "Subject: héllo\r\n\r\nBody"

    Email::MimeStore.write(@email, eml)

    assert_equal "#{@email.project_id}/#{@email.public_id}.eml", @email.mime_path
    assert_equal eml.bytesize, @email.mime_size
    assert_operator @email.mime_size, :>, eml.length, "must count bytes, not characters"
    assert Email::MimeStore.root.join(@email.mime_path).exist?
  end

  test "read round-trips the exact stored bytes" do
    eml = "raw \xC3\xA9 bytes".b
    Email::MimeStore.write(@email, eml)

    assert_equal eml, Email::MimeStore.read(@email)
  end

  test "delete removes the file and tolerates calling twice" do
    Email::MimeStore.write(@email, "bytes")
    path = Email::MimeStore.root.join(@email.mime_path)

    Email::MimeStore.delete(@email)

    assert_not path.exist?
    assert_nothing_raised { Email::MimeStore.delete(@email) }
  end

  test "delete is a no-op when nothing was ever stored" do
    assert_nothing_raised { Email::MimeStore.delete(@email) }
  end
end
```

- [ ] **Step 3: Run to verify fail**

Run: `bin/rails test test/models/email/mime_store_test.rb`
Expected: FAIL — `NameError: uninitialized constant Email::MimeStore`

- [ ] **Step 4: Implement**

```ruby
# app/models/email/mime_store.rb
class Email::MimeStore
  class << self
    def write(email, eml)
      absolute_path = root.join(relative_path(email))
      FileUtils.mkdir_p(absolute_path.dirname)
      File.binwrite(absolute_path, eml)
      email.update!(mime_path: relative_path(email), mime_size: eml.bytesize)
    end

    def read(email)
      File.binread(root.join(email.mime_path))
    end

    def delete(email)
      if email.mime_path.present?
        FileUtils.rm_f(root.join(email.mime_path))
      end
    end

    def root
      Pathname(Rails.application.config.x.mime_store_root || Rails.root.join("storage", "emails"))
    end

    private
      def relative_path(email)
        File.join(email.project_id.to_s, "#{email.public_id}.eml")
      end
  end
end
```

(Relative `mime_path` resolved against `root` at read time keeps rows portable across deploy volumes and test envs; production default `storage/emails` sits on Kamal's persistent `storage/` volume and is already gitignored.)

- [ ] **Step 5: Run, verify pass, commit**

Run: `bin/rails test`
Expected: PASS

```bash
bin/rubocop -a
git add -A
git commit -m "feat: Email::MimeStore disk wrapper with relative mime_path and byte size"
```

---

### Task 3 (roadmap 2.3): Email::Deliverable + SendEmailJob + queue.yml

**Files:**
- Create: `app/models/email/deliverable.rb`, `app/jobs/send_email_job.rb`
- Modify: `app/models/email.rb` (include the concern), `config/queue.yml` (declare `default, webhooks`)
- Test: `test/models/email/deliverable_test.rb`, `test/jobs/send_email_job_test.rb`

**Interfaces:**
- Consumes: `Email::MimeStore.read(email)` (Task 2), `Source#ses_client` (memoized + injectable, Phase 1), `mark_sending`/`mark_sent`/`mark_failed(reason)` and the strictly monotonic `advance_to` (Phase 1 `Email::Statuses`), `recipients.kind_to/kind_cc/kind_bcc` enum scopes (Phase 1), the Phase 0 ActiveJob extension (workspace capture + `enqueue_after_transaction_commit = true` — note it restores `Current.workspace` only; `Current.project`/`session` are nil inside jobs, and `deliver` touches nothing through `Current`, only through the record).
- Produces: `email.deliver` (synchronous; returns false when not deliverable; raises SES errors so the job's `retry_on` sees them; persists `ses_message_id` before `mark_sent` so a raced-in bounce event that already advanced status still leaves the id recorded), `email.deliver_later` (enqueues `SendEmailJob` on `default`). Failure semantics: 3 attempts with polynomial backoff, exhausted → `mark_failed(error.message)`. Consumed by Task 4 and Phase 4's resend.
- **Retry-guard note (roadmap correction):** the guard is `queued? || sending?`. The exhausted-retries test asserts `api_requests.size == 3` — that assertion is the regression test proving retries from `sending` still reach SES.

- [ ] **Step 1: Write the failing deliverable test**

```ruby
# test/models/email/deliverable_test.rb
require "test_helper"

class Email::DeliverableTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  STORED_EML = "raw mime bytes".freeze

  setup do
    Current.session = sessions(:owner)
    @email = create_email_with_mime
    @client = Aws::SESV2::Client.new(stub_responses: true)
    @client.stub_responses(:send_email, message_id: "ses-message-123")
    @email.source.ses_client = @client
  end

  teardown do
    Email::MimeStore.delete(@email)
  end

  test "deliver sends the stored MIME with an explicit destination and marks sent" do
    assert @email.deliver

    request = @client.api_requests.sole
    assert_equal :send_email, request[:operation_name]
    assert_equal STORED_EML, request[:params][:content][:raw][:data]
    assert_equal [ "user@example.com" ], request[:params][:destination][:to_addresses]
    assert_equal [ "copy@example.com" ], request[:params][:destination][:cc_addresses]
    assert_equal [ "hidden@example.com" ], request[:params][:destination][:bcc_addresses]

    @email.reload
    assert_equal "sent", @email.status
    assert_equal "ses-message-123", @email.ses_message_id
  end

  test "deliver from sending still sends — a retried attempt must not no-op" do
    @email.mark_sending

    @email.deliver

    assert_equal 1, @client.api_requests.size
    assert_equal "sent", @email.reload.status
  end

  test "deliver refuses emails already past sending" do
    @email.update!(status: "sent")
    assert_not @email.deliver

    @email.update!(status: "failed")
    assert_not @email.deliver

    assert_empty @client.api_requests
  end

  test "an SES error propagates for the job to retry, leaving the email sending" do
    @client.stub_responses(:send_email,
      Aws::SESV2::Errors::MessageRejected.new(nil, "Email address is not verified"))

    assert_raises Aws::SESV2::Errors::MessageRejected do
      @email.deliver
    end

    @email.reload
    assert_equal "sending", @email.status
    assert_nil @email.ses_message_id
  end

  test "deliver_later enqueues the job" do
    assert_enqueued_with(job: SendEmailJob, args: [ @email ], queue: "default") do
      @email.deliver_later
    end
  end

  private
    def create_email_with_mime
      email = Email.create!(project: projects(:acme_default), source: sources(:acme_production),
        from: "hello@acme.com", subject: "Hi", html_body: "<p>Hi</p>")
      email.recipients.create!(kind: "to", address: "user@example.com")
      email.recipients.create!(kind: "cc", address: "copy@example.com")
      email.recipients.create!(kind: "bcc", address: "hidden@example.com")
      Email::MimeStore.write(email, STORED_EML)
      email
    end
end
```

- [ ] **Step 2: Write the failing job test**

```ruby
# test/jobs/send_email_job_test.rb
require "test_helper"

class SendEmailJobTest < ActiveJob::TestCase
  setup do
    Current.session = sessions(:owner)
    @email = Email.create!(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", subject: "Hi", html_body: "<p>Hi</p>")
    @email.recipients.create!(kind: "to", address: "user@example.com")
    Email::MimeStore.write(@email, "raw mime bytes")
  end

  teardown do
    Email::MimeStore.delete(@email)
  end

  test "performs a delivery end to end" do
    stubbed = Aws::SESV2::Client.new(stub_responses: true)
    stubbed.stub_responses(:send_email, message_id: "ses-job-1")

    # GlobalID deserialization hands the job a FRESH Source instance, so a stub
    # injected on our in-memory source is lost — stub the constructor instead.
    Aws::SESV2::Client.stub :new, stubbed do
      perform_enqueued_jobs do
        SendEmailJob.perform_later(@email)
      end
    end

    @email.reload
    assert_equal "sent", @email.status
    assert_equal "ses-job-1", @email.ses_message_id
  end

  test "exhausted SES retries mark the email failed with the reason" do
    stubbed = Aws::SESV2::Client.new(stub_responses: true)
    stubbed.stub_responses(:send_email,
      Aws::SESV2::Errors::MessageRejected.new(nil, "Email address is not verified"))

    Aws::SESV2::Client.stub :new, stubbed do
      perform_enqueued_jobs do
        SendEmailJob.perform_later(@email)
      end
    end

    @email.reload
    assert_equal "failed", @email.status
    assert_equal "Email address is not verified", @email.failure_reason
    assert_equal 3, stubbed.api_requests.size, "all three attempts must reach SES (retry-guard regression)"
  end

  test "the job carries the workspace context from enqueue time" do
    stubbed = Aws::SESV2::Client.new(stub_responses: true)
    stubbed.stub_responses(:send_email, message_id: "ses-job-2")
    Current.workspace = workspaces(:acme)

    job = SendEmailJob.new(@email)
    assert_equal workspaces(:acme), job.workspace

    Current.reset
    Aws::SESV2::Client.stub :new, stubbed do
      job.perform_now
    end

    assert_equal "sent", @email.reload.status
  end
end
```

- [ ] **Step 3: Run to verify fail**

Run: `bin/rails test test/models/email/deliverable_test.rb test/jobs/send_email_job_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'deliver'` / `NameError: uninitialized constant SendEmailJob`

- [ ] **Step 4: Implement the concern, the job, and the queues**

```ruby
# app/models/email/deliverable.rb
module Email::Deliverable
  extend ActiveSupport::Concern

  def deliver
    return false unless deliverable? # guard at the start of a non-trivial body — §5.1 OK

    mark_sending
    response = source.ses_client.send_email(destination: destination,
      content: { raw: { data: Email::MimeStore.read(self) } })
    update!(ses_message_id: response.message_id)
    mark_sent
  end

  def deliver_later
    SendEmailJob.perform_later(self)
  end

  private
    def deliverable?
      queued? || sending?
    end

    def destination
      { to_addresses: recipients.kind_to.pluck(:address),
        cc_addresses: recipients.kind_cc.pluck(:address),
        bcc_addresses: recipients.kind_bcc.pluck(:address) }
    end
end
```

```ruby
# app/models/email.rb (change the includes at the top)
class Email < ApplicationRecord
  include Statuses, Deliverable
```

```ruby
# app/jobs/send_email_job.rb
class SendEmailJob < ApplicationJob
  queue_as :default

  retry_on Aws::SESV2::Errors::ServiceError, wait: :polynomially_longer, attempts: 3 do |job, error|
    job.arguments.first.mark_failed(error.message)
  end

  def perform(email)
    email.deliver
  end
end
```

```yaml
# config/queue.yml (change the workers entry; rest of the file unchanged)
default: &default
  dispatchers:
    - polling_interval: 1
      batch_size: 500
  workers:
    - queues: [ default, webhooks ]
      threads: 3
      processes: <%= ENV.fetch("JOB_CONCURRENCY", 1) %>
      polling_interval: 0.1

development:
  <<: *default

test:
  <<: *default

production:
  <<: *default
```

(`failure_reason` is written only by the `retry_on` exhaustion block — the model never rescues SES errors; they must propagate for `retry_on` to see them. **Queue gotcha:** now that worker queues are explicit, any future job enqueued to an undeclared queue silently never runs — Phase 5's `DeliverWebhookJob` uses `webhooks`, declared here already.)

- [ ] **Step 5: Run, verify pass, commit**

Run: `bin/rails test`
Expected: PASS

```bash
bin/rubocop -a
git add -A
git commit -m "feat: Email::Deliverable and SendEmailJob with SES retry and failure semantics"
```

---

### Task 4 (roadmap 2.3, wiring): MIME + delivery from EmailSubmission#save

**Files:**
- Modify: `app/models/email_submission.rb` (`create_email` tail)
- Test: `test/models/email_submission_test.rb` (append tests), `test/controllers/api/emails_controller_test.rb` (append tests)

**Interfaces:**
- Consumes: `Email::MimeBuilder.new(email, attachments: attachments).to_eml` (Task 1 — `attachments` here is the submission's in-memory array, the only place the base64 content exists), `Email::MimeStore.write` (Task 2), `email.deliver_later` (Task 3).
- Produces: `EmailSubmission#save` → persisted Email with the `.eml` on disk (`mime_path`/`mime_size` set) and `SendEmailJob` enqueued **after commit**. The API contract is unchanged: `POST /api/emails` still returns `202 { id: }` with the email `queued`.
- **Transaction placement:** the MIME build + disk write happen INSIDE the existing `Email.transaction` — a build/write failure rolls the Email back (no committed `queued` row that can never send). `deliver_later` is also called inside; `config.active_job.enqueue_after_transaction_commit = true` (Phase 0 initializer) defers the enqueue to commit, so the job never races an uncommitted row. Residual risk — an orphan `.eml` if the commit itself fails after the write — is rare, harmless, and swept by Phase 6 retention pruning.

- [ ] **Step 1: Write the failing model tests**

Append to `test/models/email_submission_test.rb`. Add `include ActiveJob::TestHelper` directly under the class line if the file doesn't have it yet, and reuse the file's existing valid-attributes helper if one exists — otherwise add the `delivery_submission` helper below alongside the new tests.

```ruby
  # --- Phase 2: MIME + delivery wiring ---

  test "save stores the MIME and enqueues delivery" do
    submission = delivery_submission

    email = nil
    assert_enqueued_with(job: SendEmailJob) do
      email = submission.save
    end

    assert_equal "queued", email.status
    assert_equal "#{email.project_id}/#{email.public_id}.eml", email.mime_path
    assert Email::MimeStore.root.join(email.mime_path).exist?
    assert_includes Email::MimeStore.read(email), "X-Departures-Id: #{email.public_id}"
  end

  test "request-time attachment bytes reach the stored MIME" do
    submission = delivery_submission(attachments: [
      { filename: "hello.txt", content_type: "text/plain", content: Base64.strict_encode64("Hello!") } ])

    email = submission.save

    parsed = Mail.read_from_string(Email::MimeStore.read(email))
    assert_equal "Hello!", parsed.attachments["hello.txt"].decoded
  end

  test "an invalid submission writes no MIME and enqueues nothing" do
    submission = delivery_submission(to: [])

    assert_no_enqueued_jobs only: SendEmailJob do
      assert_not submission.save
    end
  end

  private
    def delivery_submission(**overrides)
      EmailSubmission.new({ project: projects(:acme_default), source: sources(:acme_production),
        from: "hello@acme.com", to: [ "user@example.com" ], subject: "Hi", html: "<p>Hi</p>" }.merge(overrides))
    end
```

- [ ] **Step 2: Write the failing controller tests**

Append to `test/controllers/api/emails_controller_test.rb` (add `include ActiveJob::TestHelper` under the class line):

```ruby
  # --- Delivery wiring (Phase 2) ---

  test "an accepted submission stores the MIME and enqueues delivery" do
    assert_enqueued_with(job: SendEmailJob) do
      post_email
    end

    assert_response :accepted
    email = Email.order(:id).last
    assert_equal "queued", email.status
    assert Email::MimeStore.root.join(email.mime_path).exist?
  end

  test "an idempotent replay does not enqueue a second delivery" do
    post_email(headers: { "Idempotency-Key" => "req-90" })
    assert_response :accepted

    assert_no_enqueued_jobs only: SendEmailJob do
      post_email(headers: { "Idempotency-Key" => "req-90" })
    end

    assert_response :accepted
  end

  test "a rejected submission enqueues nothing" do
    assert_no_enqueued_jobs only: SendEmailJob do
      post_email(payload: valid_payload(to: []))
    end

    assert_response :unprocessable_entity
  end
```

- [ ] **Step 3: Run to verify fail**

Run: `bin/rails test test/models/email_submission_test.rb test/controllers/api/emails_controller_test.rb`
Expected: FAIL — the new tests fail on `assert_enqueued_with` (no job enqueued) and nil `mime_path`; all pre-existing tests still pass.

- [ ] **Step 4: Wire create_email**

```ruby
# app/models/email_submission.rb — create_email becomes:
    def create_email
      Email.transaction do
        email = Email.create!(project: project, source: source, api_key: api_key,
          from: from, subject: subject, html_body: html, text_body: text,
          headers: headers, tags: tags)

        { "to" => to, "cc" => cc, "bcc" => bcc }.each do |kind, addresses|
          addresses.each do |address|
            email.recipients.create!(kind: kind, address: address)
          end
        end

        attachments.each do |attachment|
          email.attachments.create!(filename: attachment[:filename],
            content_type: attachment[:content_type], byte_size: decoded_size(attachment))
        end

        Email::MimeStore.write(email, Email::MimeBuilder.new(email, attachments: attachments).to_eml)
        email.deliver_later

        email
      end
    end
```

- [ ] **Step 5: Run the full suite, verify pass, commit**

Run: `bin/rails test`
Expected: PASS. Pre-existing `EmailSubmission`/controller tests now also write `.eml` files (under `tmp/storage/emails`) and enqueue jobs (test adapter only queues them) — they must keep passing untouched. If `assert_enqueued_with` fails only in the *controller* tests while model tests pass, investigate how `enqueue_after_transaction_commit` interacts with the transactional-fixture wrapper before changing any production code (systematic-debugging skill).

```bash
bin/rubocop -a
git add -A
git commit -m "feat: build MIME, store the eml, and enqueue delivery from EmailSubmission#save"
```

---

### Task 5 (roadmap 2.4): Bcc spike against the SES sandbox

**Files:**
- Create: `docs/notes/bcc-ses-findings.md`

**Interfaces:**
- Consumes: Tasks 1–3 as built (no Bcc header + explicit `destination:`).
- Produces: the authoritative decision record for risk #2. Because the explicit-Destination design already guarantees bcc delivery without a header leak *by construction*, this spike **confirms** the design rather than gating the phase — it is manual (needs real SES sandbox credentials + two inboxes you control) and may be executed out of order or deferred to whenever credentials are available, but MUST be completed before Phase 5 flips the guardrails on for real sending.

- [ ] **Step 1: Run the spike (manual)**

Prerequisites: SES sandbox credentials, a verified sender identity, and two verified recipient inboxes you can read (sandbox only delivers to verified identities).

```bash
AWS_REGION=eu-west-1 SES_KEY=AKIA... SES_SECRET=... \
FROM=verified-sender@yourdomain.com TO=inbox-a@yourdomain.com BCC=inbox-b@yourdomain.com \
bin/rails runner '
  project = Project.first
  Current.workspace = project.workspace

  source = project.sources.create!(name: "Bcc spike", environment: "spike",
    region: ENV.fetch("AWS_REGION"), aws_access_key_id: ENV.fetch("SES_KEY"),
    aws_secret_access_key: ENV.fetch("SES_SECRET"), retention_days: 1)

  email = Email.create!(project: project, source: source, from: ENV.fetch("FROM"),
    subject: "Departures bcc spike", html_body: "<p>bcc spike</p>", text_body: "bcc spike")
  email.recipients.create!(kind: "to", address: ENV.fetch("TO"))
  email.recipients.create!(kind: "bcc", address: ENV.fetch("BCC"))

  Email::MimeStore.write(email, Email::MimeBuilder.new(email).to_eml)
  email.deliver
  puts "sent: #{email.ses_message_id.inspect} status: #{email.status}"

  # Variant B — headers-only raw send (no Destination), to document SES default behavior:
  email.source.ses_client.send_email(content: { raw: { data: Email::MimeStore.read(email) } })
  puts "variant B sent (recipients derived from MIME headers — bcc inbox should get NOTHING)"

  source.destroy
'
```

Then check both inboxes ("view raw source" on each message).

- [ ] **Step 2: Document the findings**

```markdown
# Bcc semantics — SESv2 raw send (risk #2 spike)

Date: <!-- fill in -->  Region: <!-- fill in -->  SDK: aws-sdk-sesv2 <!-- version -->

## Design under test
MimeBuilder never writes a Bcc header; Deliverable passes
`destination: { to_addresses:, cc_addresses:, bcc_addresses: }` alongside `content: { raw: }`.

## Checklist (Variant A — explicit Destination)
- [ ] BCC inbox received the message
- [ ] TO inbox received the message
- [ ] Raw source of the TO copy contains NO `Bcc:` header and no bcc address anywhere
- [ ] Raw source of the BCC copy contains NO `Bcc:` header (recipient can't be re-leaked)
- [ ] `Message-ID` in received copies equals `<{public_id}@{from_domain}>` (SES preserved it) — if SES
      rewrote it, note the observed value; Phase 3 matches on `ses_message_id`, not Message-ID, so this
      is informational
- [ ] `X-Departures-Id` header present in received copies

## Checklist (Variant B — no Destination, recipients derived from headers)
- [ ] TO inbox received the message
- [ ] BCC inbox received NOTHING (bcc address is in no header, so SES cannot derive it)
- [ ] Confirms: omitting Destination would silently drop bcc recipients → Destination stays mandatory

## Verdict
<!-- confirm MimeBuilder/Deliverable as built, or describe the adjustment made -->
```

- [ ] **Step 3: Commit (adjust MimeBuilder/Deliverable first if the spike contradicted the design)**

```bash
git add -A
git commit -m "docs: bcc SESv2 raw-send spike findings (risk #2)"
```

---

### Task 6: Phase wrap-up

**Files:**
- Modify: `docs/plans/departures-execution-plan.md` (Phase 2 status line), `README.md` (delivery pipeline note)

- [ ] **Step 1: Full verification**

```bash
bin/rubocop
bin/rails test
```

Expected: 0 offenses, all tests pass. Bang rule: `rg "def \w+!" app/` finds nothing new (Phase 2 defines no bang methods).

- [ ] **Step 2: Roadmap test-list audit**

Confirm each required Phase 2 test exists and passes: MIME structure assertions — parts nesting, headers, attachment encoding (Task 1) ✓; store round-trip (Task 2) ✓; `deliver` happy path with stubbed SES (Task 3) ✓; SES error → retry → failed (Task 3 job test, 3 attempts asserted) ✓; `assert_enqueued_with(job: SendEmailJob)` (Tasks 3 & 4) ✓.

- [ ] **Step 3: Manual smoke (stubbed SES — no AWS account touched)**

```bash
bin/rails runner '
  project = Project.first
  source = project.sources.first
  source.ses_client = Aws::SESV2::Client.new(stub_responses: true).tap do |client|
    client.stub_responses(:send_email, message_id: "smoke-ses-id")
  end

  submission = EmailSubmission.new(project: project, source: source,
    from: "hello@example.com", to: [ "user@example.com" ], subject: "Smoke", html: "<p>Hi</p>")
  email = submission.save
  email.deliver

  puts({ id: email.public_id, status: email.status,
         ses_message_id: email.ses_message_id, mime_path: email.mime_path }.inspect)
'
```

Expected: `status: "sent"`, `ses_message_id: "smoke-ses-id"`, `mime_path: "<project_id>/em_….eml"`, and the `.eml` exists under `storage/emails/`. (The `deliver_later` enqueued by `save` is harmless — a real worker picking it up later no-ops on the guard since the email is already `sent`.) Optionally run `bin/jobs` in another terminal to watch Solid Queue drain the `default` queue.

- [ ] **Step 4: Docs + commit**

In `docs/plans/departures-execution-plan.md`, add under the `### Phase 2` heading:
`Detailed plan: **docs/plans/phase-2-send-pipeline-plan.md** (complete).`
In README's API section, note that accepted emails are delivered asynchronously via SES (status flow `queued → sending → sent`, failures recorded in `failure_reason` after 3 attempts).

```bash
git add -A
git commit -m "chore: phase 2 wrap-up — rubocop, smoke, docs"
```

---

## Verification (phase-level)

- `bin/rails test` green; `bin/rubocop` clean.
- Roadmap Phase 2 test list fully covered (Task 6 Step 2 audit).
- The Bcc spike doc exists (or is explicitly deferred with credentials noted as the blocker — it must land before Phase 5 enables real sending).
- Standards: no business logic in `SendEmailJob` (3 lines + retry policy); Bcc never in MIME; `content.raw.data` never pre-encoded; no bang methods.
- Before starting Phase 3: author `docs/plans/phase-3-sns-ingestion-plan.md`; note the Phase 2 → Phase 3 seams: `emails.ses_message_id` is now populated and indexed (event matching key), `Email#apply_event` + `Email::Statuses` precedence guard out-of-order events, `sources.webhook_token` identifies the inbound SNS route, and `Email::MimeStore.delete` is the pruning hook Phase 6 will call.

# Phase 1 — Core Send Domain + API Accept Path — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The send domain (Source, ApiKey, Email + statuses, IdempotencyKey, Suppression skeleton, EmailSubmission form object) and the authenticated, scoped, rate-limited `POST /api/emails` accept path returning `202 { id: }`. No actual SES delivery yet (Phase 2).

**Architecture:** Everything follows `docs/patterns-and-best-practices.md`: business logic in models composed from namespaced concerns, thin controllers, `Current`-based tenancy, lambda association defaults (`belongs_to :workspace, default: -> { project.workspace }`), Minitest + fixtures. The API layer is `ActionController::API` — no sessions, no cookies; the API key is the tenant boundary.

**Tech Stack:** Rails 8.1, SQLite (`t.json` columns), `aws-sdk-sesv2`, Active Record encryption, Rails 8 `rate_limit`.

## Global Constraints

- Default integer primary keys.
- API key prefix is `dp_`. Bearer auth only (`Authorization: Bearer dp_…`). API errors are JSON: 401 `{ error: }`, 403 `{ error: }`, 409 `{ error: }`, 422 `{ errors: [ … ] }`, 429 `{ error: }`.
- Naming correction from the master plan (§5.1 bang rule — `!` only with a non-bang counterpart): `apply_event`, `mark_sending`, `mark_sent`, `mark_failed(reason)` — **no bangs**.
- Status enum (string column): `queued sending sent delivered opened clicked bounced complained failed`. `STATUS_PRECEDENCE` uses gapped values (0,10,…,80) so later phases can insert between.
- `public_id` format: `"em_" + SecureRandom.alphanumeric(24)`.
- Scope check per verb on the API: POST → `send`, GET/HEAD → `read:activity`.
- `Current.session = sessions(:owner)` in every model-test setup that touches lambda defaults (patterns gotcha §7.3.1).
- Style rules from patterns §5.1 apply to all code: expanded conditionals (guards only at the start of a non-trivial body), class methods → public (`initialize` first) → private, private methods indented and in invocation order.
- Every task ends with `bin/rails test` green and a commit. Run `bin/rubocop -a` before each commit.

**Task prelude (all tasks):** re-read patterns doc Part 2 (models/concerns/lambda defaults/scopes) and §5.1 (style). Task 8 additionally: §4.1–4.3 (controllers). No task in this phase touches views or jobs.

---

### Task 1: Prerequisites — Active Record encryption keys + aws-sdk-sesv2 gem

**Files:**
- Modify: `Gemfile`, `config/credentials.yml.enc` (via `bin/rails credentials:edit`)
- No test files (verification via `bin/rails runner`)

**Interfaces:**
- Produces: `Rails.application.credentials.active_record_encryption` non-nil (currently nil — `encrypts` in Task 2 would raise `ActiveRecord::Encryption::Errors::Configuration` without it); `Aws::SESV2::Client` available for Task 2's `ses_client`.

- [ ] **Step 1: Add the gem**

```ruby
# Gemfile (add after the solid_* block)
# AWS SES v2 API client for sending email and managing identities
gem "aws-sdk-sesv2"
```

```bash
bundle install
```

Expected: `aws-sdk-sesv2` and its `aws-sdk-core` dependencies added to `Gemfile.lock`.

- [ ] **Step 2: Generate encryption keys and install them in credentials**

```bash
bin/rails db:encryption:init | sed -n '/active_record_encryption:/,$p' > tmp/active_record_encryption_keys.yml
cat tmp/active_record_encryption_keys.yml
```

Expected output shape:

```yaml
active_record_encryption:
  primary_key: <32 random chars>
  deterministic_key: <32 random chars>
  key_derivation_salt: <32 random chars>
```

Append to credentials non-interactively (the `$0` receives the decrypted temp file path):

```bash
EDITOR='sh -c "printf \"\n\" >> $0 && cat tmp/active_record_encryption_keys.yml >> $0"' bin/rails credentials:edit
rm tmp/active_record_encryption_keys.yml
```

Fallback if the `EDITOR` trick fails: run `bin/rails credentials:edit` with your normal editor and paste the three-key block manually, then delete `tmp/active_record_encryption_keys.yml`.

- [ ] **Step 3: Verify**

```bash
bin/rails runner 'puts Rails.application.credentials.active_record_encryption.present?'
```

Expected: `true`

```bash
bin/rails runner 'require "aws-sdk-sesv2"; puts Aws::SESV2::Client.new(stub_responses: true).class'
```

Expected: `Aws::SESV2::Client`

- [ ] **Step 4: Full suite + commit**

Run: `bin/rails test`
Expected: PASS (no behavior change)

```bash
bin/rubocop -a
git add -A
git commit -m "chore: add aws-sdk-sesv2 and Active Record encryption keys"
```

---

### Task 2 (roadmap 1.1): Source model

**Files:**
- Create: migration `create_sources`, `app/models/source.rb`
- Modify: `app/models/project.rb` (`has_many :sources`)
- Test: `test/models/source_test.rb`, `test/fixtures/sources.yml`

**Interfaces:**
- Produces: `Source` with encrypted `aws_access_key_id`/`aws_secret_access_key`, `webhook_token` (has_secure_token), `source.ses_client` (memoized, injectable via `source.ses_client = Aws::SESV2::Client.new(stub_responses: true)`). Consumed by Task 8 (source resolution per environment) and Phase 2 (`deliver`), Phase 3 (webhook token lookup), Phase 5 (`Source::Quota` fills `last_quota`/`last_quota_checked_at`).

- [ ] **Step 1: Migration**

```ruby
# db/migrate/XXXX_create_sources.rb
class CreateSources < ActiveRecord::Migration[8.1]
  def change
    create_table :sources do |t|
      t.references :project, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.string :name
      t.string :environment, null: false, default: "production"
      t.string :region, null: false, default: "us-east-1"
      t.string :configuration_set
      t.string :default_from
      t.string :aws_access_key_id
      t.string :aws_secret_access_key
      t.string :webhook_token, index: { unique: true }
      t.integer :retention_days, null: false, default: 30
      t.json :last_quota
      t.datetime :last_quota_checked_at
      t.timestamps
      t.index [ :project_id, :environment ], unique: true
    end
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write failing test + fixtures**

```ruby
# test/models/source_test.rb
require "test_helper"

class SourceTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "workspace defaults to the project's workspace" do
    source = projects(:acme_default).sources.create!(environment: "staging",
      aws_access_key_id: "AKIA123", aws_secret_access_key: "secret123")

    assert_equal workspaces(:acme), source.workspace
  end

  test "aws credentials are encrypted at rest" do
    source = sources(:acme_production)

    assert_equal "AKIAACMEEXAMPLE", source.aws_access_key_id
    assert_not_equal "AKIAACMEEXAMPLE", source.ciphertext_for(:aws_access_key_id)
    assert_not_equal "acme-secret", source.ciphertext_for(:aws_secret_access_key)
  end

  test "webhook_token is generated on create" do
    source = projects(:acme_default).sources.create!(environment: "staging")

    assert source.webhook_token.present?
    assert_operator source.webhook_token.length, :>=, 24
  end

  test "environment is unique per project" do
    assert_raises ActiveRecord::RecordInvalid do
      projects(:acme_default).sources.create!(environment: "production")
    end
  end

  test "ses_client is memoized and injectable" do
    source = sources(:acme_production)
    stubbed = Aws::SESV2::Client.new(stub_responses: true)

    source.ses_client = stubbed

    assert_same stubbed, source.ses_client
    assert_same stubbed, source.ses_client
  end

  test "ses_client builds a client for the source's region" do
    client = sources(:acme_production).ses_client

    assert_instance_of Aws::SESV2::Client, client
    assert_equal "eu-west-1", client.config.region
  end
end
```

```yaml
# test/fixtures/sources.yml
acme_production:
  project: acme_default
  workspace: acme
  name: Acme production
  environment: production
  region: eu-west-1
  aws_access_key_id: AKIAACMEEXAMPLE
  aws_secret_access_key: acme-secret
  webhook_token: acme-webhook-token-1234567890
  retention_days: 30

globex_production:
  project: globex_default
  workspace: globex
  name: Globex production
  environment: production
  region: us-east-1
  aws_access_key_id: AKIAGLOBEXEXAMPLE
  aws_secret_access_key: globex-secret
  webhook_token: globex-webhook-token-1234567890
  retention_days: 30
```

Note: Rails encrypts fixture values for `encrypts` attributes automatically at insert — no manual ciphertext needed.

- [ ] **Step 3: Run to verify fail**

Run: `bin/rails test test/models/source_test.rb`
Expected: FAIL — `NameError: uninitialized constant Source`

- [ ] **Step 4: Implement**

```ruby
# app/models/source.rb
class Source < ApplicationRecord
  belongs_to :project
  belongs_to :workspace, default: -> { project.workspace }

  has_secure_token :webhook_token

  encrypts :aws_access_key_id, :aws_secret_access_key

  validates :environment, presence: true, uniqueness: { scope: :project_id }
  validates :region, presence: true
  validates :retention_days, numericality: { only_integer: true, greater_than: 0 }

  attr_writer :ses_client

  def ses_client
    @ses_client ||= Aws::SESV2::Client.new(region: region,
      credentials: Aws::Credentials.new(aws_access_key_id, aws_secret_access_key))
  end
end
```

```ruby
# app/models/project.rb (add with the other declarations)
  has_many :sources, dependent: :destroy
```

- [ ] **Step 5: Run, verify pass, commit**

Run: `bin/rails test`
Expected: PASS

```bash
bin/rubocop -a
git add -A
git commit -m "feat: sources with encrypted AWS credentials and injectable SES client"
```

---

### Task 3 (roadmap 1.2): ApiKey model

**Files:**
- Create: migration `create_api_keys`, `app/models/api_key.rb`
- Modify: `app/models/project.rb` (`has_many :api_keys`)
- Test: `test/models/api_key_test.rb`, `test/fixtures/api_keys.yml`

**Interfaces:**
- Produces: `ApiKey.issue(project:, name:, scopes:, expires_in:)` → ApiKey exposing plaintext once via `attr_reader :token`; `ApiKey.authenticate_by_token(bearer)` → active key or nil; `revoke`/`revoked?`/`expired?`/`active?`; `rotate` → replacement key; `allows?(scope)`; `touch_usage(ip:, user_agent:)` DB-throttled to 1/min. Consumed by Task 8 (auth + telemetry), Task 5 (idempotency FK), Phase 4/5 (`ApiKeys::RotationsController`).
- **Fixture token convention** (used by all later tests): plaintext tokens are `"dp_" + <4 chars> * 12` so tests can re-derive them; fixtures store only the SHA-256.

- [ ] **Step 1: Migration**

```ruby
# db/migrate/XXXX_create_api_keys.rb
class CreateApiKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :api_keys do |t|
      t.references :project, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.string :name
      t.string :prefix, null: false
      t.string :key_hash, null: false, index: { unique: true }
      t.json :scopes, null: false, default: []
      t.datetime :expires_at
      t.datetime :revoked_at
      t.datetime :last_used_at
      t.string :last_used_ip
      t.string :last_used_user_agent
      t.timestamps
    end
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write failing test + fixtures**

```yaml
# test/fixtures/api_keys.yml
# Plaintext tokens (re-derived in tests): "dp_" + <4 chars> * 12
acme_full:
  project: acme_default
  workspace: acme
  name: Acme full access
  prefix: dp_acmeacmea
  key_hash: <%= Digest::SHA256.hexdigest("dp_" + "acme" * 12) %>
  scopes: ["send", "read:activity"]

acme_read_only:
  project: acme_default
  workspace: acme
  name: Acme read only
  prefix: dp_readreadr
  key_hash: <%= Digest::SHA256.hexdigest("dp_" + "read" * 12) %>
  scopes: ["read:activity"]

acme_send_only:
  project: acme_default
  workspace: acme
  name: Acme send only
  prefix: dp_mailmailm
  key_hash: <%= Digest::SHA256.hexdigest("dp_" + "mail" * 12) %>
  scopes: ["send"]

acme_revoked:
  project: acme_default
  workspace: acme
  name: Acme revoked
  prefix: dp_gonegoneg
  key_hash: <%= Digest::SHA256.hexdigest("dp_" + "gone" * 12) %>
  scopes: ["send", "read:activity"]
  revoked_at: <%= 1.day.ago %>

acme_expired:
  project: acme_default
  workspace: acme
  name: Acme expired
  prefix: dp_latelatel
  key_hash: <%= Digest::SHA256.hexdigest("dp_" + "late" * 12) %>
  scopes: ["send", "read:activity"]
  expires_at: <%= 1.hour.ago %>

globex_full:
  project: globex_default
  workspace: globex
  name: Globex full access
  prefix: dp_globglobg
  key_hash: <%= Digest::SHA256.hexdigest("dp_" + "glob" * 12) %>
  scopes: ["send", "read:activity"]
```

```ruby
# test/models/api_key_test.rb
require "test_helper"

class ApiKeyTest < ActiveSupport::TestCase
  ACME_FULL_TOKEN = "dp_#{"acme" * 12}".freeze

  setup do
    Current.session = sessions(:owner)
  end

  test "issue returns a key exposing the plaintext token exactly once" do
    api_key = ApiKey.issue(project: projects(:acme_default), scopes: %w[ send ])

    assert api_key.persisted?
    assert api_key.token.start_with?("dp_")
    assert_equal 51, api_key.token.length
    assert_equal api_key.token.first(12), api_key.prefix
    assert_equal Digest::SHA256.hexdigest(api_key.token), api_key.key_hash
    assert_equal workspaces(:acme), api_key.workspace
    assert_nil ApiKey.find(api_key.id).token
  end

  test "issue with expires_in sets expiry" do
    api_key = ApiKey.issue(project: projects(:acme_default), scopes: %w[ send ], expires_in: 30.days)

    assert_in_delta 30.days.from_now, api_key.expires_at, 5.seconds
  end

  test "authenticate_by_token finds the key by sha256" do
    assert_equal api_keys(:acme_full), ApiKey.authenticate_by_token(ACME_FULL_TOKEN)
  end

  test "authenticate_by_token rejects unknown, revoked, and expired tokens" do
    assert_nil ApiKey.authenticate_by_token("dp_bogus")
    assert_nil ApiKey.authenticate_by_token("dp_#{"gone" * 12}")
    assert_nil ApiKey.authenticate_by_token("dp_#{"late" * 12}")
    assert_nil ApiKey.authenticate_by_token(nil)
  end

  test "revoke is idempotent and flips active?" do
    api_key = api_keys(:acme_full)
    assert api_key.active?

    api_key.revoke
    first_revoked_at = api_key.revoked_at
    assert api_key.revoked?
    assert_not api_key.active?

    api_key.revoke
    assert_equal first_revoked_at, api_key.revoked_at
  end

  test "rotate revokes the old key and issues a replacement with the same scopes" do
    api_key = api_keys(:acme_full)

    replacement = api_key.rotate

    assert api_key.reload.revoked?
    assert replacement.persisted?
    assert replacement.token.present?
    assert_equal api_key.scopes, replacement.scopes
    assert_equal api_key.project, replacement.project
  end

  test "allows? checks scopes" do
    assert api_keys(:acme_full).allows?("send")
    assert api_keys(:acme_read_only).allows?("read:activity")
    assert_not api_keys(:acme_read_only).allows?("send")
  end

  test "touch_usage records telemetry at most once per minute" do
    api_key = api_keys(:acme_full)

    api_key.touch_usage(ip: "1.2.3.4", user_agent: "curl")
    first_touch = api_key.reload.last_used_at
    assert_equal "1.2.3.4", api_key.last_used_ip

    api_key.touch_usage(ip: "5.6.7.8", user_agent: "curl")
    assert_equal first_touch, api_key.reload.last_used_at
    assert_equal "1.2.3.4", api_key.last_used_ip

    api_key.update_columns(last_used_at: 2.minutes.ago)
    api_key.touch_usage(ip: "5.6.7.8", user_agent: "curl")
    assert_equal "5.6.7.8", api_key.reload.last_used_ip
  end
end
```

- [ ] **Step 3: Run to verify fail**

Run: `bin/rails test test/models/api_key_test.rb`
Expected: FAIL — `NameError: uninitialized constant ApiKey`

- [ ] **Step 4: Implement**

```ruby
# app/models/api_key.rb
class ApiKey < ApplicationRecord
  belongs_to :project
  belongs_to :workspace, default: -> { project.workspace }

  scope :active, -> { where(revoked_at: nil).and(where(expires_at: nil).or(where(expires_at: Time.current..))) }

  validates :prefix, presence: true
  validates :key_hash, presence: true, uniqueness: true

  attr_reader :token

  class << self
    def issue(project:, name: nil, scopes: [], expires_in: nil)
      token = "dp_#{SecureRandom.alphanumeric(48)}"

      create!(project: project, name: name, scopes: scopes, prefix: token.first(12),
        key_hash: digest(token), expires_at: expires_in&.from_now).tap do |api_key|
        api_key.instance_variable_set(:@token, token)
      end
    end

    def authenticate_by_token(bearer)
      if bearer.present?
        active.find_by(key_hash: digest(bearer))
      end
    end

    def digest(token)
      Digest::SHA256.hexdigest(token)
    end
  end

  def revoked?
    revoked_at.present?
  end

  def expired?
    expires_at.present? && expires_at.past?
  end

  def active?
    !revoked? && !expired?
  end

  def revoke
    unless revoked?
      update! revoked_at: Time.current
    end
  end

  def rotate
    transaction do
      revoke
      self.class.issue(project: project, name: name, scopes: scopes)
    end
  end

  def allows?(scope)
    scopes.include?(scope.to_s)
  end

  def touch_usage(ip:, user_agent:)
    if last_used_at.nil? || last_used_at < 1.minute.ago
      update_columns(last_used_at: Time.current, last_used_ip: ip, last_used_user_agent: user_agent)
    end
  end
end
```

`touch_usage` uses `update_columns` deliberately: pure telemetry, no validations/callbacks/updated_at churn (SQLite write hygiene, risk #3).

```ruby
# app/models/project.rb (add)
  has_many :api_keys, dependent: :destroy
```

- [ ] **Step 5: Run, verify pass, commit**

Run: `bin/rails test`
Expected: PASS

```bash
bin/rubocop -a
git add -A
git commit -m "feat: API keys with sha256 digests, scopes, rotation, and throttled telemetry"
```

---

### Task 4 (roadmap 1.3): Email + Email::Statuses + recipients + attachments

**Files:**
- Create: migrations `create_emails`, `create_email_recipients`, `create_email_attachments`; `app/models/email.rb`, `app/models/email/statuses.rb`, `app/models/email_recipient.rb`, `app/models/email_attachment.rb`
- Modify: `app/models/project.rb` (`has_many :emails`, `deletable?` → `archived? && emails.none?`)
- Test: `test/models/email/statuses_test.rb`, `test/models/email_test.rb`, `test/models/project_test.rb` (new), `test/fixtures/emails.yml`

**Interfaces:**
- Produces: `Email` with `public_id` (before_create), string-backed status enum, `Email::Statuses::STATUS_PRECEDENCE`, `apply_event(event_type)` (forward-only, returns true/false), `mark_sending`/`mark_sent`/`mark_failed(reason)`; `email.recipients` (kinds to/cc/bcc), `email.attachments` (metadata). Consumed by Task 7 (`EmailSubmission#save`), Phase 2 (`Deliverable`), Phase 3 (`apply_event` from SNS).
- Body columns `html_body`/`text_body` persist so Phase 2 can build MIME at deliver time (decision — see plan header).

- [ ] **Step 1: Migrations**

```ruby
# db/migrate/XXXX_create_emails.rb
class CreateEmails < ActiveRecord::Migration[8.1]
  def change
    create_table :emails do |t|
      t.references :project, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.references :source, null: false, foreign_key: true
      t.references :api_key, foreign_key: true
      t.string :public_id, null: false, index: { unique: true }
      t.string :status, null: false, default: "queued"
      t.string :from, null: false
      t.string :subject
      t.text :html_body
      t.text :text_body
      t.string :ses_message_id, index: true
      t.json :headers, null: false, default: {}
      t.json :tags, null: false, default: {}
      t.string :mime_path
      t.integer :mime_size
      t.string :failure_reason
      t.timestamps
      t.index [ :project_id, :status, :created_at ]
    end
  end
end
```

```ruby
# db/migrate/XXXX_create_email_recipients.rb
class CreateEmailRecipients < ActiveRecord::Migration[8.1]
  def change
    create_table :email_recipients do |t|
      t.references :email, null: false, foreign_key: true
      t.string :kind, null: false, default: "to"
      t.string :address, null: false, index: true
      t.timestamps
    end
  end
end
```

```ruby
# db/migrate/XXXX_create_email_attachments.rb
class CreateEmailAttachments < ActiveRecord::Migration[8.1]
  def change
    create_table :email_attachments do |t|
      t.references :email, null: false, foreign_key: true
      t.string :filename, null: false
      t.string :content_type
      t.integer :byte_size, null: false, default: 0
      t.timestamps
    end
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write failing tests + fixture**

```yaml
# test/fixtures/emails.yml
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
```

```ruby
# test/models/email/statuses_test.rb
require "test_helper"

class Email::StatusesTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    @email = emails(:acme_welcome)
  end

  # event applied to current status => expected resulting status
  PRECEDENCE_TABLE = [
    [ "queued",     "delivery",  "delivered"  ],
    [ "sent",       "delivery",  "delivered"  ],
    [ "delivered",  "open",      "opened"     ],
    [ "opened",     "click",     "clicked"    ],
    [ "clicked",    "delivery",  "clicked"    ], # never regresses
    [ "clicked",    "open",      "clicked"    ], # never regresses
    [ "delivered",  "bounce",    "bounced"    ],
    [ "bounced",    "complaint", "complained" ],
    [ "complained", "bounce",    "complained" ], # complaint outranks bounce
    [ "sent",       "send",      "sent"       ], # same status is not a forward move
    [ "queued",     "reject",    "failed"     ]
  ].freeze

  test "apply_event only ever advances status" do
    PRECEDENCE_TABLE.each do |current, event, expected|
      @email.update_columns(status: current)

      @email.apply_event(event)

      assert_equal expected, @email.reload.status, "#{current} + #{event} should be #{expected}"
    end
  end

  test "apply_event returns false and is a no-op for unknown event types" do
    assert_not @email.apply_event("subscription")
    assert_equal "queued", @email.reload.status
  end

  test "mark_sending, mark_sent advance forward only" do
    assert @email.mark_sending
    assert_equal "sending", @email.status

    assert @email.mark_sent
    assert_equal "sent", @email.status

    assert_not @email.mark_sending
    assert_equal "sent", @email.reload.status
  end

  test "mark_failed records the reason" do
    assert @email.mark_failed("MessageRejected: address not verified")

    assert_equal "failed", @email.status
    assert_equal "MessageRejected: address not verified", @email.failure_reason
  end

  test "precedence map covers every enum status" do
    assert_equal Email.statuses.keys.sort, Email::Statuses::STATUS_PRECEDENCE.keys.sort
  end
end
```

```ruby
# test/models/email_test.rb
require "test_helper"

class EmailTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "public_id is assigned before create with the em_ prefix" do
    email = projects(:acme_default).emails.create!(source: sources(:acme_production),
      from: "hello@acme.com", subject: "Hi")

    assert_match(/\Aem_[a-zA-Z0-9]{24}\z/, email.public_id)
  end

  test "workspace defaults to the project's workspace" do
    email = projects(:acme_default).emails.create!(source: sources(:acme_production),
      from: "hello@acme.com", subject: "Hi")

    assert_equal workspaces(:acme), email.workspace
  end

  test "recipients and attachments are destroyed with the email" do
    email = emails(:acme_welcome)
    email.recipients.create!(kind: "to", address: "user@example.com")
    email.attachments.create!(filename: "a.pdf", byte_size: 10)

    assert_difference -> { EmailRecipient.count } => -1, -> { EmailAttachment.count } => -1 do
      email.destroy
    end
  end
end
```

```ruby
# test/models/project_test.rb
require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  test "deletable? requires archived and no emails" do
    project = projects(:globex_default)
    assert_not project.deletable?

    project.archive
    assert project.deletable?

    project.emails.create!(source: sources(:globex_production), from: "hello@globex.com", subject: "Hi")
    assert_not project.deletable?
  end
end
```

- [ ] **Step 3: Run to verify fail**

Run: `bin/rails test test/models/email/statuses_test.rb test/models/email_test.rb test/models/project_test.rb`
Expected: FAIL — `NameError: uninitialized constant Email`

- [ ] **Step 4: Implement**

```ruby
# app/models/email/statuses.rb
module Email::Statuses
  extend ActiveSupport::Concern

  STATUS_PRECEDENCE = {
    "queued" => 0, "sending" => 10, "sent" => 20, "delivered" => 30,
    "opened" => 40, "clicked" => 50, "bounced" => 60, "complained" => 70, "failed" => 80
  }.freeze

  EVENT_STATUSES = {
    "send" => "sent", "delivery" => "delivered", "open" => "opened", "click" => "clicked",
    "bounce" => "bounced", "complaint" => "complained", "reject" => "failed"
  }.freeze

  included do
    enum :status, STATUS_PRECEDENCE.keys.index_by(&:itself), default: "queued", validate: true
  end

  def apply_event(event_type)
    status_for_event = EVENT_STATUSES[event_type.to_s]

    if status_for_event
      advance_to(status_for_event)
    else
      false
    end
  end

  def mark_sending
    advance_to("sending")
  end

  def mark_sent
    advance_to("sent")
  end

  def mark_failed(reason)
    advance_to("failed", failure_reason: reason)
  end

  private
    def advance_to(new_status, **attributes)
      if STATUS_PRECEDENCE.fetch(new_status) > STATUS_PRECEDENCE.fetch(status)
        update!(status: new_status, **attributes)
        true
      else
        false
      end
    end
end
```

```ruby
# app/models/email.rb
class Email < ApplicationRecord
  include Statuses

  belongs_to :project
  belongs_to :workspace, default: -> { project.workspace }
  belongs_to :source
  belongs_to :api_key, optional: true

  has_many :recipients, class_name: "EmailRecipient", dependent: :destroy
  has_many :attachments, class_name: "EmailAttachment", dependent: :destroy

  validates :from, presence: true

  before_create :assign_public_id

  private
    def assign_public_id
      self.public_id ||= "em_#{SecureRandom.alphanumeric(24)}"
    end
end
```

```ruby
# app/models/email_recipient.rb
class EmailRecipient < ApplicationRecord
  belongs_to :email

  enum :kind, %w[ to cc bcc ].index_by(&:itself), default: "to", prefix: true

  validates :address, presence: true
end
```

```ruby
# app/models/email_attachment.rb
class EmailAttachment < ApplicationRecord
  belongs_to :email

  validates :filename, presence: true
  validates :byte_size, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
```

```ruby
# app/models/project.rb (add association; change deletable?)
  has_many :emails, dependent: :destroy

  def deletable?
    archived? && emails.none?
  end
```

- [ ] **Step 5: Run, verify pass, commit**

Run: `bin/rails test`
Expected: PASS

```bash
bin/rubocop -a
git add -A
git commit -m "feat: emails with forward-only status precedence, recipients, attachment metadata"
```

---

### Task 5 (roadmap 1.4): IdempotencyKey

**Files:**
- Create: migration `create_idempotency_keys`, `app/models/idempotency_key.rb`
- Modify: `app/models/api_key.rb` (`has_many :idempotency_keys`)
- Test: `test/models/idempotency_key_test.rb`

**Interfaces:**
- Produces: `IdempotencyKey.replay_or_record(api_key:, key:, fingerprint:) { block }` → block result when key blank or first-seen (recorded only when the block returns an email); existing email on replay; raises `IdempotencyKey::MismatchError` on fingerprint conflict (Task 8 maps → 409). `IdempotencyKey.prune_expired` seam for Phase 6.

- [ ] **Step 1: Migration**

```ruby
# db/migrate/XXXX_create_idempotency_keys.rb
class CreateIdempotencyKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :idempotency_keys do |t|
      t.references :api_key, null: false, foreign_key: true
      t.references :email, null: false, foreign_key: true
      t.string :key, null: false
      t.string :fingerprint, null: false
      t.datetime :expires_at, null: false
      t.timestamps
      t.index [ :api_key_id, :key ], unique: true
    end
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write failing test**

```ruby
# test/models/idempotency_key_test.rb
require "test_helper"

class IdempotencyKeyTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    @api_key = api_keys(:acme_full)
    @email = emails(:acme_welcome)
  end

  test "first call runs the block and records the result" do
    result = nil

    assert_difference -> { IdempotencyKey.count }, +1 do
      result = IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: "fp-1") { @email }
    end

    assert_equal @email, result
    record = IdempotencyKey.last
    assert_equal @email, record.email
    assert_in_delta 24.hours.from_now, record.expires_at, 5.seconds
  end

  test "matching replay returns the existing email without re-running the block" do
    IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: "fp-1") { @email }
    block_ran = false

    result = IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: "fp-1") do
      block_ran = true
    end

    assert_equal @email, result
    assert_not block_ran
  end

  test "fingerprint conflict raises MismatchError" do
    IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: "fp-1") { @email }

    assert_raises IdempotencyKey::MismatchError do
      IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: "fp-DIFFERENT") { @email }
    end
  end

  test "a blank key just runs the block" do
    assert_no_difference -> { IdempotencyKey.count } do
      assert_equal @email, IdempotencyKey.replay_or_record(api_key: @api_key, key: nil, fingerprint: "fp-1") { @email }
    end
  end

  test "a falsy block result is not recorded" do
    assert_no_difference -> { IdempotencyKey.count } do
      assert_equal false, IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: "fp-1") { false }
    end
  end

  test "keys are scoped per api key" do
    IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: "fp-1") { @email }
    other_email = emails(:acme_welcome).dup.tap { |e| e.public_id = nil; e.save! }

    result = IdempotencyKey.replay_or_record(api_key: api_keys(:acme_send_only), key: "req-1", fingerprint: "fp-1") { other_email }

    assert_equal other_email, result
  end

  test "expired keys are replaced, not replayed" do
    IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: "fp-1") { @email }
    IdempotencyKey.last.update_columns(expires_at: 1.hour.ago)
    replacement = emails(:acme_welcome).dup.tap { |e| e.public_id = nil; e.save! }

    result = IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: "fp-2") { replacement }

    assert_equal replacement, result
  end

  test "prune_expired removes only expired rows" do
    IdempotencyKey.replay_or_record(api_key: @api_key, key: "old", fingerprint: "fp") { @email }
    IdempotencyKey.replay_or_record(api_key: @api_key, key: "fresh", fingerprint: "fp") { @email }
    IdempotencyKey.find_by(key: "old").update_columns(expires_at: 1.hour.ago)

    IdempotencyKey.prune_expired

    assert_equal %w[ fresh ], IdempotencyKey.pluck(:key)
  end
end
```

- [ ] **Step 3: Run to verify fail**

Run: `bin/rails test test/models/idempotency_key_test.rb`
Expected: FAIL — `NameError: uninitialized constant IdempotencyKey`

- [ ] **Step 4: Implement**

```ruby
# app/models/idempotency_key.rb
class IdempotencyKey < ApplicationRecord
  EXPIRY = 24.hours

  class MismatchError < StandardError; end

  belongs_to :api_key
  belongs_to :email

  scope :active, -> { where(expires_at: Time.current..) }
  scope :expired, -> { where(expires_at: ...Time.current) }

  validates :key, presence: true, uniqueness: { scope: :api_key_id }
  validates :fingerprint, presence: true

  class << self
    def replay_or_record(api_key:, key:, fingerprint:, &block)
      if key.blank?
        return block.call
      end

      existing = active.find_by(api_key: api_key, key: key)

      if existing
        replay(existing, fingerprint)
      else
        record(api_key, key, fingerprint, &block)
      end
    end

    def prune_expired
      expired.in_batches.delete_all
    end

    private
      def replay(existing, fingerprint)
        if existing.fingerprint == fingerprint
          existing.email
        else
          raise MismatchError
        end
      end

      def record(api_key, key, fingerprint)
        email = yield

        if email
          expired.where(api_key: api_key, key: key).delete_all
          create!(api_key: api_key, key: key, fingerprint: fingerprint, email: email, expires_at: EXPIRY.from_now)
        end

        email
      rescue ActiveRecord::RecordNotUnique
        replay(active.find_by!(api_key: api_key, key: key), fingerprint)
      end
  end
end
```

Note: the `RecordNotUnique` rescue handles the concurrent-duplicate race — the loser replays the winner's email (its own just-created email is an accepted, rare orphan).

```ruby
# app/models/api_key.rb (add)
  has_many :idempotency_keys, dependent: :destroy
```

- [ ] **Step 5: Run, verify pass, commit**

Run: `bin/rails test`
Expected: PASS

```bash
bin/rubocop -a
git add -A
git commit -m "feat: idempotency keys with replay, fingerprint mismatch, and prune seam"
```

---

### Task 6 (roadmap 1.5): Suppression skeleton

**Files:**
- Create: migration `create_suppressions`, `app/models/suppression.rb`
- Modify: `app/models/project.rb` (`has_many :suppressions`)
- Test: `test/models/suppression_test.rb`, `test/fixtures/suppressions.yml`

**Interfaces:**
- Produces: expiry-aware `Suppression.active`; `Suppression.covers?(project, addresses)` → array of suppressed addresses (subset). Consumed by Task 7's `validate_suppressed_recipients` and Phase 3 (creation on bounce/complaint).

- [ ] **Step 1: Migration**

```ruby
# db/migrate/XXXX_create_suppressions.rb
class CreateSuppressions < ActiveRecord::Migration[8.1]
  def change
    create_table :suppressions do |t|
      t.references :project, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.string :email, null: false
      t.string :reason, null: false
      t.datetime :expires_at
      t.timestamps
      t.index [ :project_id, :email ], unique: true
    end
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write failing test + fixtures**

```yaml
# test/fixtures/suppressions.yml
acme_blocked:
  project: acme_default
  workspace: acme
  email: blocked@example.com
  reason: complaint

acme_lapsed:
  project: acme_default
  workspace: acme
  email: lapsed@example.com
  reason: bounce
  expires_at: <%= 1.day.ago %>

acme_temporary:
  project: acme_default
  workspace: acme
  email: temporary@example.com
  reason: bounce
  expires_at: <%= 1.week.from_now %>
```

```ruby
# test/models/suppression_test.rb
require "test_helper"

class SuppressionTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "active includes permanent and unexpired suppressions only" do
    assert_includes Suppression.active, suppressions(:acme_blocked)
    assert_includes Suppression.active, suppressions(:acme_temporary)
    assert_not_includes Suppression.active, suppressions(:acme_lapsed)
  end

  test "covers? returns the suppressed subset" do
    covered = Suppression.covers?(projects(:acme_default),
      %w[ blocked@example.com fine@example.com temporary@example.com ])

    assert_equal %w[ blocked@example.com temporary@example.com ], covered.sort
  end

  test "covers? ignores expired suppressions" do
    assert_empty Suppression.covers?(projects(:acme_default), %w[ lapsed@example.com ])
  end

  test "covers? is project-scoped" do
    assert_empty Suppression.covers?(projects(:globex_default), %w[ blocked@example.com ])
  end

  test "covers? normalizes case and whitespace" do
    assert_equal %w[ blocked@example.com ], Suppression.covers?(projects(:acme_default), [ " Blocked@Example.COM " ])
  end

  test "email is unique per project and workspace defaults from project" do
    suppression = projects(:globex_default).suppressions.create!(email: "blocked@example.com", reason: "manual")
    assert_equal workspaces(:globex), suppression.workspace

    assert_raises ActiveRecord::RecordInvalid do
      projects(:acme_default).suppressions.create!(email: "blocked@example.com", reason: "manual")
    end
  end
end
```

- [ ] **Step 3: Run to verify fail**

Run: `bin/rails test test/models/suppression_test.rb`
Expected: FAIL — `NameError: uninitialized constant Suppression`

- [ ] **Step 4: Implement**

```ruby
# app/models/suppression.rb
class Suppression < ApplicationRecord
  belongs_to :project
  belongs_to :workspace, default: -> { project.workspace }

  scope :active, -> { where(expires_at: nil).or(where(expires_at: Time.current..)) }

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, presence: true, uniqueness: { scope: :project_id }
  validates :reason, presence: true

  class << self
    def covers?(project, addresses)
      normalized = Array(addresses).map { |address| address.to_s.strip.downcase }
      active.where(project: project, email: normalized).pluck(:email)
    end
  end
end
```

(`covers?` returning the suppressed subset — an array — is the master plan's named interface; the truthiness of `covers?(…).any?` still reads correctly at call sites.)

```ruby
# app/models/project.rb (add)
  has_many :suppressions, dependent: :destroy
```

- [ ] **Step 4b: Run, verify pass, commit**

Run: `bin/rails test`
Expected: PASS

```bash
bin/rubocop -a
git add -A
git commit -m "feat: suppression skeleton with expiry-aware active scope and covers?"
```

---

### Task 7 (roadmap 1.6): EmailSubmission form object

**Files:**
- Create: `app/models/email_submission.rb`
- Test: `test/models/email_submission_test.rb`

**Interfaces:**
- Consumes: `Email`/`EmailRecipient`/`EmailAttachment` (Task 4), `Suppression.covers?` (Task 6).
- Produces: `EmailSubmission.new(project:, source:, api_key:, from:, to:, cc:, bcc:, subject:, template_id:, html:, text:, headers:, tags:, attachments:)`; `valid?` runs the full matrix; `save` → persisted `Email` (with recipients + attachment metadata, one transaction) or `false`. Private guardrail seams (`from_domain_verified?`, `quota_fresh?`, `complaint_breaker_tripped?`) return pass-through values until Phase 5. Phase 2 adds `deliver_later` after this `save`.
- Attachment shape: `{ filename:, content_type:, content: <base64 string> }`; only metadata is persisted (decoded size estimated as `content.length * 3 / 4`).

- [ ] **Step 1: Write failing test (the full validation matrix)**

```ruby
# test/models/email_submission_test.rb
require "test_helper"

class EmailSubmissionTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  def valid_attributes(**overrides)
    { project: projects(:acme_default), source: sources(:acme_production), api_key: api_keys(:acme_full),
      from: "hello@acme.com", to: [ "user@example.com" ], subject: "Hi", html: "<p>Hi</p>" }.merge(overrides)
  end

  def submission(**overrides)
    EmailSubmission.new(valid_attributes(**overrides))
  end

  test "a valid submission saves an email with recipients and attachment metadata" do
    content = Base64.strict_encode64("PDF BYTES")
    subject = submission(cc: [ "cc@example.com" ], bcc: [ "bcc@example.com" ],
      headers: { "X-Campaign" => "welcome" }, tags: { "team" => "growth" },
      attachments: [ { filename: "a.pdf", content_type: "application/pdf", content: content } ])

    email = nil
    assert_difference -> { Email.count } => +1, -> { EmailRecipient.count } => +3, -> { EmailAttachment.count } => +1 do
      email = subject.save
    end

    assert_kind_of Email, email
    assert email.persisted?
    assert_equal "queued", email.status
    assert_equal "hello@acme.com", email.from
    assert_equal [ "user@example.com" ], email.recipients.kind_to.pluck(:address)
    assert_equal [ "cc@example.com" ], email.recipients.kind_cc.pluck(:address)
    assert_equal [ "bcc@example.com" ], email.recipients.kind_bcc.pluck(:address)
    assert_equal({ "X-Campaign" => "welcome" }, email.headers)
    assert_equal "a.pdf", email.attachments.sole.filename
    assert_equal (content.length * 3) / 4, email.attachments.sole.byte_size
    assert_equal api_keys(:acme_full), email.api_key
  end

  test "save returns false and persists nothing when invalid" do
    subject = submission(to: [])

    assert_no_difference -> { Email.count } do
      assert_equal false, subject.save
    end
  end

  test "from is required and must be an email address" do
    assert_not submission(from: nil).valid?
    assert_not submission(from: "not-an-email").valid?
  end

  test "at least one to recipient is required" do
    subject = submission(to: [])

    assert_not subject.valid?
    assert subject.errors[:to].any?
  end

  test "recipient addresses must be valid and at most 1000 characters" do
    assert_not submission(to: [ "not-an-email" ]).valid?
    assert_not submission(cc: [ "cc-broken" ]).valid?
    assert_not submission(bcc: [ "bcc-broken" ]).valid?
    assert_not submission(to: [ "#{"a" * 995}@example.com" ]).valid?
    assert submission(to: [ "user@example.com" ]).valid?
  end

  test "total recipients across to, cc, and bcc are capped at 50" do
    addresses = ->(n, tag) { n.times.map { |i| "#{tag}#{i}@example.com" } }
    assert submission(to: addresses.(20, "t"), cc: addresses.(20, "c"), bcc: addresses.(10, "b")).valid?

    subject = submission(to: addresses.(20, "t"), cc: addresses.(20, "c"), bcc: addresses.(11, "b"))
    assert_not subject.valid?
    assert subject.errors[:base].any? { |m| m.include?("50") }
  end

  test "subject XOR template" do
    assert_not submission(subject: nil, template_id: nil).valid?
    assert_not submission(subject: "Hi", template_id: 42).valid?
    assert submission(subject: nil, template_id: 42, html: "<p>Hi</p>").valid?
  end

  test "html or text body is required without a template" do
    assert_not submission(html: nil, text: nil).valid?
    assert submission(html: nil, text: "Hi").valid?
  end

  test "at most 25 attachments" do
    attachments = 26.times.map { |i| { filename: "f#{i}.txt", content: Base64.strict_encode64("x") } }

    subject = submission(attachments: attachments)

    assert_not subject.valid?
    assert subject.errors[:attachments].any?
  end

  test "attachments are capped at 30 MB total decoded size" do
    big = Base64.strict_encode64("x" * 16.megabytes)
    subject = submission(attachments: [
      { filename: "a.bin", content: big }, { filename: "b.bin", content: big }
    ])

    assert_not subject.valid?
    assert subject.errors[:attachments].any? { |m| m.include?("30") }
  end

  test "attachments require a filename" do
    assert_not submission(attachments: [ { content: Base64.strict_encode64("x") } ]).valid?
  end

  test "reserved headers are rejected" do
    %w[ From To Subject Message-ID DKIM-Signature Content-Type X-Departures-Id ].each do |header|
      subject = submission(headers: { header => "value" })

      assert_not subject.valid?, "#{header} should be reserved"
      assert subject.errors[:headers].any?
    end

    assert submission(headers: { "X-Campaign" => "ok" }).valid?
  end

  test "suppressed recipients are rejected with their addresses listed" do
    subject = submission(to: [ "user@example.com", "blocked@example.com" ], bcc: [ "temporary@example.com" ])

    assert_not subject.valid?
    message = subject.errors[:base].sole
    assert_includes message, "blocked@example.com"
    assert_includes message, "temporary@example.com"
  end

  test "expired suppressions do not block sends" do
    assert submission(to: [ "lapsed@example.com" ]).valid?
  end

  test "project and source are required" do
    assert_not submission(project: nil).valid?
    assert_not submission(source: nil).valid?
  end

  test "scalar recipients are normalized to arrays for internal callers" do
    assert submission(to: "user@example.com").valid?
  end
end
```

- [ ] **Step 2: Run to verify fail**

Run: `bin/rails test test/models/email_submission_test.rb`
Expected: FAIL — `NameError: uninitialized constant EmailSubmission`

- [ ] **Step 3: Implement**

```ruby
# app/models/email_submission.rb
class EmailSubmission
  include ActiveModel::Model

  MAX_ADDRESS_LENGTH = 1000
  MAX_TOTAL_RECIPIENTS = 50
  MAX_ATTACHMENT_COUNT = 25
  MAX_ATTACHMENT_BYTES = 30.megabytes

  RESERVED_HEADERS = %w[
    from to cc bcc subject date message-id return-path received mime-version
    content-type content-transfer-encoding dkim-signature x-departures-id
  ].freeze

  ADDRESS_FORMAT = URI::MailTo::EMAIL_REGEXP

  attr_accessor :project, :source, :api_key, :from, :subject, :template_id, :html, :text
  attr_reader :to, :cc, :bcc, :headers, :tags, :attachments

  validates :project, :source, presence: true

  validate :validate_from,
    :validate_recipient_lists,
    :validate_total_recipients,
    :validate_subject_xor_template,
    :validate_body_presence,
    :validate_attachments,
    :validate_reserved_headers,
    :validate_suppressed_recipients,
    :validate_guardrails

  def initialize(attributes = {})
    @to, @cc, @bcc = [], [], []
    @headers, @tags = {}, {}
    @attachments = []
    super
  end

  def to=(addresses)
    @to = Array(addresses).map(&:to_s)
  end

  def cc=(addresses)
    @cc = Array(addresses).map(&:to_s)
  end

  def bcc=(addresses)
    @bcc = Array(addresses).map(&:to_s)
  end

  def headers=(value)
    @headers = (value || {}).to_h.transform_keys(&:to_s)
  end

  def tags=(value)
    @tags = (value || {}).to_h.transform_keys(&:to_s)
  end

  def attachments=(value)
    @attachments = Array(value).map { |attachment| attachment.to_h.symbolize_keys }
  end

  def save
    if valid?
      create_email
    else
      false
    end
  end

  private
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

        email
      end
    end

    def validate_from
      if from.blank?
        errors.add(:from, "is required")
      elsif !valid_address?(from)
        errors.add(:from, "is not a valid email address")
      end
    end

    def validate_recipient_lists
      if to.empty?
        errors.add(:to, "must contain at least one recipient")
      end

      { to: to, cc: cc, bcc: bcc }.each do |field, addresses|
        addresses.each do |address|
          unless valid_address?(address)
            errors.add(field, "contains an invalid address: #{address.truncate(60)}")
          end
        end
      end
    end

    def validate_total_recipients
      if all_recipients.size > MAX_TOTAL_RECIPIENTS
        errors.add(:base, "cannot exceed #{MAX_TOTAL_RECIPIENTS} total recipients across to, cc, and bcc")
      end
    end

    def validate_subject_xor_template
      if subject.present? && template_id.present?
        errors.add(:base, "provide either subject or template_id, not both")
      elsif subject.blank? && template_id.blank?
        errors.add(:subject, "is required unless template_id is given")
      end
    end

    def validate_body_presence
      if template_id.blank? && html.blank? && text.blank?
        errors.add(:base, "html or text body is required")
      end
    end

    def validate_attachments
      if attachments.size > MAX_ATTACHMENT_COUNT
        errors.add(:attachments, "cannot exceed #{MAX_ATTACHMENT_COUNT} files")
      end

      attachments.each do |attachment|
        if attachment[:filename].blank?
          errors.add(:attachments, "must each have a filename")
        end
      end

      if attachments.sum { |attachment| decoded_size(attachment) } > MAX_ATTACHMENT_BYTES
        errors.add(:attachments, "cannot exceed 30 MB in total")
      end
    end

    def validate_reserved_headers
      headers.each_key do |name|
        if RESERVED_HEADERS.include?(name.downcase)
          errors.add(:headers, "#{name} is a reserved header")
        end
      end
    end

    def validate_suppressed_recipients
      if project
        suppressed = Suppression.covers?(project, all_recipients)

        if suppressed.any?
          errors.add(:base, "recipients are suppressed: #{suppressed.join(", ")}")
        end
      end
    end

    def validate_guardrails
      unless from_domain_verified?
        errors.add(:from, "domain is not verified")
      end

      unless quota_fresh?
        errors.add(:base, "sending quota information is stale")
      end

      if complaint_breaker_tripped?
        errors.add(:base, "sending is paused due to complaint rate")
      end
    end

    def all_recipients
      to + cc + bcc
    end

    def valid_address?(address)
      address.length <= MAX_ADDRESS_LENGTH && address.match?(ADDRESS_FORMAT)
    end

    def decoded_size(attachment)
      (attachment[:content].to_s.length * 3) / 4
    end

    # Guardrail seams — wired up in Phase 5 (Source::Quota, Domain verification, complaint breaker).
    def from_domain_verified?
      true
    end

    def quota_fresh?
      true
    end

    def complaint_breaker_tripped?
      false
    end
end
```

- [ ] **Step 4: Run, verify pass, commit**

Run: `bin/rails test`
Expected: PASS

```bash
bin/rubocop -a
git add -A
git commit -m "feat: EmailSubmission form object with the full validation matrix and guardrail seams"
```

---

### Task 8 (roadmap 1.7): Api::BaseController + Api::EmailsController + routes

**Files:**
- Create: `app/controllers/api/base_controller.rb`, `app/controllers/api/emails_controller.rb`
- Modify: `config/routes.rb`, `config/environments/test.rb` (cache store — see Step 1)
- Test: `test/controllers/api/emails_controller_test.rb`

**Interfaces:**
- Consumes: `ApiKey.authenticate_by_token`/`allows?`/`touch_usage` (Task 3), `EmailSubmission` (Task 7), `IdempotencyKey.replay_or_record` (Task 5).
- Produces: `POST /api/emails` → 202 `{ id: <public_id> }`; `GET /api/emails` → 200 `{ data: [ … ] }`; JSON errors 401/403/409/422/429. `Current.workspace`/`Current.project` set from the key for the whole request (jobs enqueued later inherit workspace via the Phase 0 ActiveJob extension).
- **Risk #5 note:** `rate_limit` (actionpack 8.1) registers a plain `before_action` at declaration point, so declaring it after `before_action :authenticate_api_key` guarantees it runs post-auth with `@api_key` set; a failed auth halts the chain before the limiter. If a future Rails version changes this ordering, switch to the fallback `by: -> { request.headers["Authorization"].to_s }`.

- [ ] **Step 1: Enable a real cache store in test (rate limiting counts through it)**

```ruby
# config/environments/test.rb — replace the null_store line
  config.cache_store = :memory_store
```

(Each parallel test worker is a separate process with its own memory store; the rate-limit test clears the cache in `setup`.)

- [ ] **Step 2: Write failing controller test**

```ruby
# test/controllers/api/emails_controller_test.rb
require "test_helper"

class Api::EmailsControllerTest < ActionDispatch::IntegrationTest
  ACME_FULL_TOKEN = "dp_#{"acme" * 12}".freeze
  ACME_READ_ONLY_TOKEN = "dp_#{"read" * 12}".freeze
  ACME_SEND_ONLY_TOKEN = "dp_#{"mail" * 12}".freeze
  ACME_REVOKED_TOKEN = "dp_#{"gone" * 12}".freeze
  ACME_EXPIRED_TOKEN = "dp_#{"late" * 12}".freeze
  GLOBEX_FULL_TOKEN = "dp_#{"glob" * 12}".freeze

  setup do
    Rails.cache.clear
  end

  def valid_payload(**overrides)
    { from: "hello@acme.com", to: [ "user@example.com" ], subject: "Hi", html: "<p>Hi</p>" }.merge(overrides)
  end

  def auth(token)
    { "Authorization" => "Bearer #{token}" }
  end

  def post_email(token: ACME_FULL_TOKEN, payload: valid_payload, headers: {})
    post api_emails_url, params: payload, headers: auth(token).merge(headers), as: :json
  end

  # --- Authentication (401) ---

  test "missing bearer token is unauthorized" do
    post api_emails_url, params: valid_payload, as: :json

    assert_response :unauthorized
    assert_equal "Unauthorized", response.parsed_body["error"]
  end

  test "unknown, revoked, and expired tokens are unauthorized" do
    [ "dp_bogus", ACME_REVOKED_TOKEN, ACME_EXPIRED_TOKEN ].each do |token|
      post_email(token: token)

      assert_response :unauthorized
    end
  end

  # --- Scope matrix (403) ---

  test "POST requires the send scope" do
    post_email(token: ACME_READ_ONLY_TOKEN)

    assert_response :forbidden
    assert_includes response.parsed_body["error"], "send"
  end

  test "GET requires the read:activity scope" do
    get api_emails_url, headers: auth(ACME_SEND_ONLY_TOKEN)

    assert_response :forbidden

    get api_emails_url, headers: auth(ACME_READ_ONLY_TOKEN)

    assert_response :success
  end

  # --- Create (202) ---

  test "a valid submission is accepted with the public id" do
    assert_difference -> { Email.count }, +1 do
      post_email
    end

    assert_response :accepted
    email = Email.order(:id).last
    assert_equal email.public_id, response.parsed_body["id"]
    assert_equal projects(:acme_default), email.project
    assert_equal sources(:acme_production), email.source
    assert_equal api_keys(:acme_full), email.api_key
  end

  test "emails are created under the key's project, not any other tenant" do
    post_email(token: GLOBEX_FULL_TOKEN, payload: valid_payload(from: "hello@globex.com"))

    assert_response :accepted
    assert_equal projects(:globex_default), Email.order(:id).last.project
  end

  test "authenticated requests touch key usage telemetry" do
    post_email

    assert api_keys(:acme_full).reload.last_used_at.present?
  end

  # --- Validation errors (422) ---

  test "an invalid submission returns the error list" do
    post_email(payload: valid_payload(to: [], html: nil, subject: nil))

    assert_response :unprocessable_entity
    errors = response.parsed_body["errors"]
    assert_kind_of Array, errors
    assert errors.any? { |e| e.include?("recipient") }
  end

  test "suppressed recipients are rejected listing the addresses" do
    post_email(payload: valid_payload(to: [ "blocked@example.com" ]))

    assert_response :unprocessable_entity
    assert response.parsed_body["errors"].any? { |e| e.include?("blocked@example.com") }
  end

  test "an unknown environment returns 422" do
    post_email(payload: valid_payload(environment: "staging"))

    assert_response :unprocessable_entity
  end

  # --- Idempotency (replay + 409) ---

  test "replaying an idempotency key returns the same email without creating another" do
    post_email(headers: { "Idempotency-Key" => "req-42" })
    assert_response :accepted
    first_id = response.parsed_body["id"]

    assert_no_difference -> { Email.count } do
      post_email(headers: { "Idempotency-Key" => "req-42" })
    end

    assert_response :accepted
    assert_equal first_id, response.parsed_body["id"]
  end

  test "reusing an idempotency key with a different body conflicts" do
    post_email(headers: { "Idempotency-Key" => "req-42" })

    post_email(payload: valid_payload(subject: "Changed"), headers: { "Idempotency-Key" => "req-42" })

    assert_response :conflict
    assert response.parsed_body["error"].present?
  end

  test "failed validations are not recorded against the idempotency key" do
    post_email(payload: valid_payload(to: []), headers: { "Idempotency-Key" => "req-43" })
    assert_response :unprocessable_entity

    assert_difference -> { Email.count }, +1 do
      post_email(headers: { "Idempotency-Key" => "req-43" })
    end

    assert_response :accepted
  end

  # --- Rate limiting (429, risk #5) ---

  test "requests beyond 60 per minute per key are rejected" do
    60.times do
      get api_emails_url, headers: auth(ACME_FULL_TOKEN)
      assert_response :success
    end

    get api_emails_url, headers: auth(ACME_FULL_TOKEN)

    assert_response :too_many_requests
    assert_equal "Too many requests", response.parsed_body["error"]
  end

  test "the rate limiter runs after authentication, so unauthenticated requests get 401 not an error" do
    post api_emails_url, params: valid_payload, as: :json

    assert_response :unauthorized
  end

  # --- Index ---

  test "index returns the project's latest emails" do
    get api_emails_url, headers: auth(ACME_FULL_TOKEN)

    assert_response :success
    data = response.parsed_body["data"]
    assert data.any? { |row| row["id"] == emails(:acme_welcome).public_id }
    assert(data.all? { |row| row.key?("status") && row.key?("created_at") })
  end
end
```

- [ ] **Step 3: Run to verify fail**

Run: `bin/rails test test/controllers/api/emails_controller_test.rb`
Expected: FAIL — `NameError: undefined local variable or method 'api_emails_url'`

- [ ] **Step 4: Implement routes and controllers**

```ruby
# config/routes.rb (add above the health check)
  namespace :api do
    resources :emails, only: %i[ index create ]
  end
```

```ruby
# app/controllers/api/base_controller.rb
class Api::BaseController < ActionController::API
  before_action :authenticate_api_key
  before_action :ensure_scope

  # Declared after the auth before_action so @api_key is always set when the
  # limiter runs (actionpack registers rate_limit as a before_action in
  # declaration order — risk #5). Fallback if that ever changes:
  # by: -> { request.headers["Authorization"].to_s }
  rate_limit to: 60, within: 1.minute, by: -> { @api_key.id },
    with: -> { render json: { error: "Too many requests" }, status: :too_many_requests }

  private
    def authenticate_api_key
      @api_key = ApiKey.authenticate_by_token(bearer_token)

      if @api_key
        Current.workspace = @api_key.workspace
        Current.project = @api_key.project
        @api_key.touch_usage(ip: request.remote_ip, user_agent: request.user_agent)
      else
        render json: { error: "Unauthorized" }, status: :unauthorized
      end
    end

    def bearer_token
      request.headers["Authorization"].to_s[/\ABearer (.+)\z/, 1]
    end

    def ensure_scope
      unless @api_key.allows?(required_scope)
        render json: { error: "Forbidden: this key is missing the #{required_scope} scope" }, status: :forbidden
      end
    end

    def required_scope
      if request.get? || request.head?
        "read:activity"
      else
        "send"
      end
    end
end
```

```ruby
# app/controllers/api/emails_controller.rb
class Api::EmailsController < Api::BaseController
  before_action :set_source, only: :create

  def index
    emails = Current.project.emails.order(created_at: :desc).limit(50)

    render json: { data: emails.map { |email| { id: email.public_id, status: email.status, created_at: email.created_at } } }
  end

  def create
    @submission = EmailSubmission.new(submission_attributes)

    email = IdempotencyKey.replay_or_record(api_key: @api_key,
      key: request.headers["Idempotency-Key"], fingerprint: request_fingerprint) do
      @submission.save
    end

    if email
      render json: { id: email.public_id }, status: :accepted
    else
      render json: { errors: @submission.errors.full_messages }, status: :unprocessable_entity
    end
  rescue IdempotencyKey::MismatchError
    render json: { error: "Idempotency-Key was already used with a different request body" }, status: :conflict
  end

  private
    def set_source
      @source = Current.project.sources.find_by(environment: params.fetch(:environment, Current.project.default_environment))

      if @source.nil?
        render json: { errors: [ "No source is configured for this environment" ] }, status: :unprocessable_entity
      end
    end

    def submission_attributes
      params.permit(:from, :subject, :html, :text, :template_id,
        to: [], cc: [], bcc: [], headers: {}, tags: {},
        attachments: [ %i[ filename content_type content ] ])
        .to_h.merge(project: Current.project, source: @source, api_key: @api_key)
    end

    def request_fingerprint
      Digest::SHA256.hexdigest(request.raw_post)
    end
end
```

- [ ] **Step 5: Run, verify pass**

Run: `bin/rails test test/controllers/api/emails_controller_test.rb`
Expected: PASS (the 429 test makes 61 GETs — a few seconds is normal)

Run: `bin/rails test`
Expected: PASS (full suite; confirms the test-env cache store change broke nothing)

- [ ] **Step 6: Commit**

```bash
bin/rubocop -a
git add -A
git commit -m "feat: authenticated, scoped, rate-limited API accept path for emails"
```

---

### Task 9: Phase wrap-up

**Files:**
- Modify: `README.md` (API quickstart)

- [ ] **Step 1: Full verification**

```bash
bin/rubocop
bin/rails test
```

Expected: 0 offenses, all tests pass. Also verify the bang rule: `rg "def \w+!" app/` finds nothing new (Phase 1 defines no bang methods).

- [ ] **Step 2: Roadmap test-list audit**

Confirm each required test exists and passes: issue/authenticate/revoke/rotate key (Task 3) ✓; scope matrix (Task 8) ✓; rate-limit 429 (Task 8) ✓; idempotent replay + 409 mismatch (Tasks 5, 8) ✓; full EmailSubmission validation matrix (Task 7) ✓; suppressed recipients 422 (Tasks 7, 8) ✓; status precedence table (Task 4) ✓.

- [ ] **Step 3: Manual smoke**

```bash
bin/rails runner '
  Current.workspace = Workspace.first
  project = Project.first
  project.sources.find_or_create_by!(environment: "production") { |s| s.aws_access_key_id = "AKIA"; s.aws_secret_access_key = "secret" }
  key = ApiKey.issue(project: project, scopes: %w[ send read:activity ])
  puts key.token
'
bin/dev
```

Then in another terminal (replace `$TOKEN`):

```bash
curl -i -X POST http://localhost:3000/api/emails \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -H "Idempotency-Key: smoke-1" \
  -d '{"from":"hello@example.com","to":["user@example.com"],"subject":"Smoke","html":"<p>Hi</p>"}'
```

Expected: `202 Accepted` with `{"id":"em_…"}`; repeating the exact curl returns the same id; changing the body with the same `Idempotency-Key` returns 409; `curl http://localhost:3000/api/emails -H "Authorization: Bearer $TOKEN"` lists it.

- [ ] **Step 4: README + commit**

Add an "API" section to README: bearer auth, `POST /api/emails` payload shape (arrays for to/cc/bcc), `Idempotency-Key` header, 60 req/min per key limit, error format.

```bash
git add -A
git commit -m "chore: phase 1 wrap-up — rubocop, docs, smoke"
```

---

## Verification (phase-level)

- `bin/rails test` green; `bin/rubocop` clean.
- Roadmap Phase 1 test list fully covered (Task 9 Step 2 audit).
- No delivery occurs (Phase 2): accepted emails stay `queued`.
- Before starting Phase 2: author `docs/plans/phase-2-send-pipeline-plan.md`; note the Phase 1 → Phase 2 seams: `Email#html_body`/`text_body` for MimeBuilder, attachment content is request-time-only (MIME likely built during submission), `EmailSubmission#save` is where `deliver_later` gets appended.

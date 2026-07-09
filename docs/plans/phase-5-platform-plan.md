# Phase 5 — Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Domains/DKIM verification, send guardrails (verified from-domain, quota freshness, complaint breaker), outbound customer webhooks with signed deliveries, templates with `{{ var }}` rendering, Sources & API keys management UIs, and the onboarding wizard with a first-run gate.

**Architecture:** All business logic in models/concerns (`Domain`, `Source::Quota`, `WebhookEndpoint`, `WebhookDelivery`, `Template`, `Workspace::Onboardable`); thin RESTful controllers with capability checks; the one job (`DeliverWebhookJob`) is a 6-line `_later` wrapper on queue `:webhooks`. The three guardrail seams left in `EmailSubmission` (Phase 1) and the fan-out seam in `WebhookLog#process` (Phase 3) get wired for real. SES calls go through `Source#ses_client` / `Domain#ses_client`, stubbed in tests.

**Tech Stack:** Rails 8.1, SQLite, Hotwire (Turbo + Stimulus), `aws-sdk-sesv2`, Active Record encryption, Net::HTTP (outbound webhooks), OpenSSL HMAC.

## Global Constraints

- Default integer primary keys. No new gems.
- Webhook signature header is exactly `Departures-Signature: t={ts},v1={sig}` (HMAC-SHA256 over `"{ts}.{body}"` with the endpoint secret).
- Webhook endpoint secrets are `whsec_` + 32 alphanumerics, AR-encrypted, revealed once in the UI.
- API key prefix `dp_` (already built — Phase 5 only adds the UI).
- Bang methods only when a non-bang counterpart exists: `sync_quota`, `mark_failed`, `mark_onboarded`, `provision`, `check` — no bangs.
- Registration open only while `User.none?` or `ENV["OPEN_REGISTRATION"]` (unchanged).
- Guards OK only at method start before a non-trivial body; expanded conditionals otherwise. Method order: class methods → public (`initialize` first) → private, private methods in invocation order, indented under `private` with no blank line after the modifier.
- Dashboard controllers scope through `Current.workspace` / `Current.project`; cross-tenant access 404s. Capability failures 403 via `authorize_capability!`.
- All tests Minitest + fixtures. `Current.session = sessions(:owner)` in model-test setups touching lambda defaults. AWS clients always stubbed. `bin/rails test` + `bin/rubocop` green at the end of every task.
- CSS: tokens only, `@layer modules` for feature CSS, logical properties, light + dark verified.

## Standards preludes

Before each task, re-read the named sections:

- Model tasks (1, 3, 6, 7, 10, 14): `docs/patterns-and-best-practices.md` Part 2 (concerns, intention-revealing APIs, scopes, callbacks) + §5.1 (style).
- Controller tasks (2, 5, 9, 11, 13, 14): patterns Part 4.1–4.3 (thin controllers, RESTful resources, concerns).
- Job task (7): patterns §4.4–4.5 (`_now`/`_later`, workspace context).
- View tasks (2, 5, 9, 11, 13, 14): `docs/style-guide.md` (tokens, buttons, inputs, icons, dark mode).

---

### Task 1: `Domain` model — provision, check, decommission, `verifies?`

**Files:**
- Create: `db/migrate/<timestamp>_create_domains.rb` (via generator)
- Create: `app/models/domain.rb`
- Create: `test/fixtures/domains.yml`
- Create: `test/models/domain_test.rb`
- Modify: `app/models/project.rb` (association)
- Modify: `app/models/source.rb` (`ses_client` stubbed in test env)
- Modify: `test/test_helper.rb` (`wipe_workspace_records` order)

**Interfaces:**
- Consumes: `Source#ses_client` (memoized `Aws::SESV2::Client`), `project.workspace` lambda-default pattern.
- Produces: `Domain.verifies?(project, address) → true/false` (verified-domain check incl. subdomains, used by Task 4); `Domain#provision → true/false` (SES `create_email_identity`, stores DKIM tokens); `Domain#check → true/false` (SES `get_email_identity`, advances `status` to `verified`); `Domain#decommission` (best-effort SES `delete_email_identity` + destroy); `Domain#dkim_records → [{ name:, value: }]`; enum predicates `pending?` / `verified?` / `failed?`; `Domain#ses_client` with `attr_writer :ses_client` for test injection; `project.domains` association.

- [ ] **Step 1: Generate the migration**

Run: `bin/rails generate migration CreateDomains`

Replace the generated file's contents with:

```ruby
class CreateDomains < ActiveRecord::Migration[8.1]
  def change
    create_table :domains do |t|
      t.references :project, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.string :name, null: false
      t.string :status, default: "pending", null: false
      t.json :dkim_tokens, default: [], null: false
      t.datetime :last_checked_at

      t.timestamps
    end

    add_index :domains, %i[ project_id name ], unique: true
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Make `Source#ses_client` stub-safe in tests**

The dashboard controllers added in this phase call SES inline (domain provisioning, quota sync). Controller tests cannot inject a per-instance client, so the client itself must never hit AWS from the test env. In `app/models/source.rb` replace the `ses_client` method:

```ruby
  def ses_client
    @ses_client ||= Aws::SESV2::Client.new(region: region,
      credentials: Aws::Credentials.new(aws_access_key_id, aws_secret_access_key),
      stub_responses: Rails.env.test?)
  end
```

Existing model tests keep injecting their own stubbed clients via `attr_writer :ses_client`; this only guards the default path.

- [ ] **Step 3: Write fixtures**

Create `test/fixtures/domains.yml`:

```yaml
acme_com:
  project: acme_default
  workspace: acme
  name: acme.com
  status: verified
  dkim_tokens: [ "acmetok1", "acmetok2", "acmetok3" ]

acme_pending:
  project: acme_default
  workspace: acme
  name: staging-acme.io
  status: pending
  dkim_tokens: [ "stagetok1", "stagetok2", "stagetok3" ]

globex_com:
  project: globex_default
  workspace: globex
  name: globex.com
  status: verified
  dkim_tokens: [ "globextok1", "globextok2", "globextok3" ]
```

- [ ] **Step 4: Write the failing tests**

Create `test/models/domain_test.rb`:

```ruby
require "test_helper"

class DomainTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "workspace defaults from the project" do
    domain = projects(:acme_default).domains.create!(name: "mail.acme.com")

    assert_equal workspaces(:acme), domain.workspace
    assert domain.pending?
  end

  test "name is normalized, validated, and unique per project" do
    domain = projects(:acme_default).domains.create!(name: "  Mail.Acme.COM  ")
    assert_equal "mail.acme.com", domain.name

    duplicate = projects(:acme_default).domains.build(name: "MAIL.ACME.COM")
    assert_not duplicate.valid?

    other_project = projects(:globex_default).domains.build(name: "mail.acme.com")
    assert other_project.valid?

    assert_not projects(:acme_default).domains.build(name: "not a domain").valid?
    assert_not projects(:acme_default).domains.build(name: "").valid?
  end

  test "verifies? matches verified domains and their subdomains only" do
    project = projects(:acme_default)

    assert Domain.verifies?(project, "hello@acme.com")
    assert Domain.verifies?(project, "no-reply@mail.acme.com")
    assert_not Domain.verifies?(project, "hello@staging-acme.io"), "pending domains must not verify"
    assert_not Domain.verifies?(project, "hello@acme.com.evil.io"), "suffix must match on label boundary"
    assert_not Domain.verifies?(project, "hello@globex.com"), "other tenants' domains must not verify"
    assert_not Domain.verifies?(project, "not-an-address")
    assert_not Domain.verifies?(project, nil)
  end

  test "provision creates the SES identity and stores DKIM tokens" do
    domain = domain_with_client
    domain.ses_client.stub_responses(:create_email_identity,
      dkim_attributes: { tokens: %w[ tok1 tok2 tok3 ] })

    assert domain.provision
    assert_equal %w[ tok1 tok2 tok3 ], domain.dkim_tokens
    assert domain.pending?
  end

  test "provision falls back to check when the identity already exists" do
    domain = domain_with_client
    domain.ses_client.stub_responses(:create_email_identity, "AlreadyExistsException")
    domain.ses_client.stub_responses(:get_email_identity,
      verified_for_sending_status: true, dkim_attributes: { tokens: %w[ tok1 ] })

    assert domain.provision
    assert domain.verified?
  end

  test "provision marks the domain failed on SES errors" do
    domain = domain_with_client
    domain.ses_client.stub_responses(:create_email_identity, "TooManyRequestsException")

    assert_not domain.provision
    assert domain.failed?
  end

  test "check verifies, keeps pending, or fails by SES status" do
    domain = domain_with_client

    domain.ses_client.stub_responses(:get_email_identity,
      verified_for_sending_status: false, dkim_attributes: { tokens: %w[ tok1 ] })
    assert_not domain.check
    assert domain.pending?
    assert domain.last_checked_at.present?

    domain.ses_client.stub_responses(:get_email_identity,
      verified_for_sending_status: true, dkim_attributes: { tokens: %w[ tok1 ] })
    assert domain.check
    assert domain.verified?

    domain.ses_client.stub_responses(:get_email_identity, "NotFoundException")
    assert_not domain.check
    assert domain.failed?
  end

  test "dkim_records builds the CNAME pairs" do
    records = domains(:acme_com).dkim_records

    assert_equal 3, records.size
    assert_equal "acmetok1._domainkey.acme.com", records.first[:name]
    assert_equal "acmetok1.dkim.amazonses.com", records.first[:value]
  end

  test "decommission destroys the record even when SES deletion fails" do
    domain = domain_with_client
    domain.ses_client.stub_responses(:delete_email_identity, "NotFoundException")

    domain.decommission
    assert_not Domain.exists?(domain.id)
  end

  private
    def domain_with_client
      domain = projects(:acme_default).domains.create!(name: "mail.acme.com")
      domain.ses_client = Aws::SESV2::Client.new(stub_responses: true)
      domain
    end
end
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `bin/rails test test/models/domain_test.rb`
Expected: FAIL (uninitialized constant `Domain`)

- [ ] **Step 6: Implement `Domain`**

Create `app/models/domain.rb`:

```ruby
class Domain < ApplicationRecord
  NAME_FORMAT = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/

  belongs_to :project
  belongs_to :workspace, default: -> { project.workspace }

  enum :status, %w[ pending verified failed ].index_by(&:itself), default: "pending", validate: true

  normalizes :name, with: ->(name) { name.strip.downcase }

  validates :name, presence: true, uniqueness: { scope: :project_id },
    format: { with: NAME_FORMAT, message: "is not a valid domain name" }

  attr_writer :ses_client

  def self.verifies?(project, address)
    host = address.to_s[/@([^@\s]+)\z/, 1]&.downcase
    return false if host.blank?

    project.domains.verified.pluck(:name).any? do |name|
      host == name || host.end_with?(".#{name}")
    end
  end

  def provision
    response = ses_client.create_email_identity(email_identity: name)
    update!(dkim_tokens: Array(response.dkim_attributes&.tokens))
    true
  rescue Aws::SESV2::Errors::AlreadyExistsException
    check
  rescue Aws::SESV2::Errors::ServiceError
    update!(status: "failed")
    false
  end

  def check
    response = ses_client.get_email_identity(email_identity: name)
    update!(status: response.verified_for_sending_status ? "verified" : "pending",
      dkim_tokens: Array(response.dkim_attributes&.tokens).presence || dkim_tokens,
      last_checked_at: Time.current)
    verified?
  rescue Aws::SESV2::Errors::NotFoundException
    update!(status: "failed", last_checked_at: Time.current)
    false
  rescue Aws::SESV2::Errors::ServiceError
    false
  end

  def decommission
    ses_client.delete_email_identity(email_identity: name)
    destroy
  rescue Aws::SESV2::Errors::ServiceError
    destroy
  end

  def dkim_records
    dkim_tokens.map do |token|
      { name: "#{token}._domainkey.#{name}", value: "#{token}.dkim.amazonses.com" }
    end
  end

  def ses_client
    @ses_client ||= source.ses_client
  end

  private
    def source
      project.sources.order(:id).first
    end
end
```

In `app/models/project.rb`, add alongside the existing `has_many` declarations:

```ruby
  has_many :domains, dependent: :destroy
```

In `test/test_helper.rb`, inside `wipe_workspace_records`, add before `Project.delete_all`:

```ruby
      Domain.delete_all
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `bin/rails test test/models/domain_test.rb`
Expected: PASS

- [ ] **Step 8: Full suite + rubocop, then commit**

Run: `bin/rails test && bin/rubocop`
Expected: green (nothing consumes `Domain.verifies?` yet, so no behavior change elsewhere)

```bash
git add db/migrate db/schema.rb app/models/domain.rb app/models/project.rb app/models/source.rb test/fixtures/domains.yml test/models/domain_test.rb test/test_helper.rb
git commit -m "feat: Domain model with SES provision/check and verified-domain lookup"
```

---

### Task 2: Domains dashboard — `DomainsController` + `Domains::ChecksController`

**Files:**
- Create: `app/controllers/domains_controller.rb`
- Create: `app/controllers/domains/checks_controller.rb`
- Create: `app/views/domains/index.html.erb`
- Create: `app/assets/stylesheets/settings.css`
- Modify: `config/routes.rb`
- Modify: `app/views/layouts/_nav.html.erb`
- Create: `test/controllers/domains_controller_test.rb`

**Interfaces:**
- Consumes: `Domain#provision`, `Domain#check`, `Domain#decommission`, `Domain#dkim_records`, `Current.project.domains`, `authorize_capability! :manage_domains`, `RequiresProject`, `icon_tag`, clipboard Stimulus controller.
- Produces: routes `domains_path` (`GET/POST /domains`), `domain_path` (`DELETE`), `domain_check_path` (`POST /domains/:domain_id/check`). Used by nav and the onboarding wizard (Task 14).

- [ ] **Step 1: Write the failing controller tests**

Create `test/controllers/domains_controller_test.rb`:

```ruby
require "test_helper"

class DomainsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
  end

  test "index lists only the current project's domains" do
    get domains_url

    assert_response :success
    assert_match "acme.com", response.body
    assert_no_match "globex.com", response.body
  end

  test "create provisions the domain and shows DKIM records" do
    assert_difference -> { projects(:acme_default).domains.count }, +1 do
      post domains_url, params: { domain: { name: "mail.acme.com" } }
    end

    assert_redirected_to domains_url
    assert projects(:acme_default).domains.exists?(name: "mail.acme.com")
  end

  test "create rejects an invalid domain name" do
    assert_no_difference -> { Domain.count } do
      post domains_url, params: { domain: { name: "not a domain" } }
    end

    assert_redirected_to domains_url
    assert flash[:alert].present?
  end

  test "create requires a source to provision against" do
    sign_in_as users(:outsider)
    wipe_send_domain # globex's email fixture holds an FK to its source
    projects(:globex_default).sources.destroy_all

    assert_no_difference -> { Domain.count } do
      post domains_url, params: { domain: { name: "mail.globex.com" } }
    end

    assert_redirected_to domains_url
    assert flash[:alert].present?
  end

  test "check re-verifies the domain" do
    post domain_check_url(domains(:acme_pending))

    assert_redirected_to domains_url
    assert domains(:acme_pending).reload.last_checked_at.present?
  end

  test "destroy decommissions the domain" do
    assert_difference -> { Domain.count }, -1 do
      delete domain_url(domains(:acme_pending))
    end

    assert_redirected_to domains_url
  end

  test "cross-tenant domains 404" do
    delete domain_url(domains(:globex_com))
    assert_response :not_found

    post domain_check_url(domains(:globex_com))
    assert_response :not_found
  end

  test "mutations require the manage_domains capability" do
    sign_in_as users(:read_only)

    post domains_url, params: { domain: { name: "mail.acme.com" } }
    assert_response :forbidden

    post domain_check_url(domains(:acme_pending))
    assert_response :forbidden

    delete domain_url(domains(:acme_pending))
    assert_response :forbidden
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/domains_controller_test.rb`
Expected: FAIL (no route matches `domains_url`)

- [ ] **Step 3: Add routes**

In `config/routes.rb`, after the `resources :suppressions` line:

```ruby
  resources :domains, only: %i[ index create destroy ] do
    scope module: :domains do
      resource :check, only: :create
    end
  end
```

- [ ] **Step 4: Implement the controllers**

Create `app/controllers/domains_controller.rb`:

```ruby
class DomainsController < ApplicationController
  include RequiresProject

  skip_before_action :require_project, only: :index
  before_action -> { authorize_capability! :manage_domains }, only: %i[ create destroy ]

  def index
    if Current.project
      @domains = Current.project.domains.order(:name)
    end
  end

  def create
    if Current.project.sources.none?
      redirect_to domains_path, alert: "Add a source before adding domains."
    else
      @domain = Current.project.domains.new(domain_params)

      if @domain.save
        @domain.provision
        redirect_to domains_path, notice: "Domain added. Create the DNS records below, then re-check."
      else
        redirect_to domains_path, alert: @domain.errors.full_messages.to_sentence
      end
    end
  end

  def destroy
    Current.project.domains.find(params[:id]).decommission
    redirect_to domains_path, notice: "Domain removed."
  end

  private
    def domain_params
      params.require(:domain).permit(:name)
    end
end
```

Create `app/controllers/domains/checks_controller.rb`:

```ruby
class Domains::ChecksController < ApplicationController
  include RequiresProject

  before_action -> { authorize_capability! :manage_domains }

  def create
    domain = Current.project.domains.find(params[:domain_id])

    if domain.check
      redirect_to domains_path, notice: "#{domain.name} is verified."
    else
      redirect_to domains_path, alert: "#{domain.name} is not verified yet. DNS can take a while to propagate."
    end
  end
end
```

- [ ] **Step 5: Build the view, nav link, and CSS**

Create `app/views/domains/index.html.erb`:

```erb
<% content_for :title, "Domains" %>

<% if Current.project %>
  <header class="page-header">
    <h1>Domains</h1>
  </header>

  <% if Current.workspace.capability?(Current.user, :manage_domains) %>
    <%= form_with model: Domain.new, url: domains_path, class: "inline-form" do |form| %>
      <%= form.text_field :name, class: "input", placeholder: "mail.example.com", required: true,
            aria: { label: "Domain name" } %>
      <%= form.submit "Add domain", class: "btn btn--primary btn--medium" %>
    <% end %>
  <% end %>

  <% if @domains.any? %>
    <% @domains.each do |domain| %>
      <article class="settings-card">
        <header class="settings-card__header">
          <h2><%= domain.name %></h2>
          <span class="status-pill status-pill--<%= domain.verified? ? "delivered" : "queued" %>">
            <%= domain.status %>
          </span>

          <% if Current.workspace.capability?(Current.user, :manage_domains) %>
            <%= button_to "Re-check DNS", domain_check_path(domain), class: "btn btn--secondary btn--medium" %>
            <%= button_to domain_path(domain), method: :delete, class: "btn btn--destroy btn--medium",
                  aria: { label: "Remove #{domain.name}" },
                  data: { turbo_confirm: "Remove #{domain.name}? Sending from it will stop working." } do %>
              <%= icon_tag "trash" %>
            <% end %>
          <% end %>
        </header>

        <% if domain.dkim_records.any? && !domain.verified? %>
          <table class="settings-table">
            <thead>
              <tr><th>CNAME name</th><th>CNAME value</th><th></th></tr>
            </thead>
            <tbody>
              <% domain.dkim_records.each do |record| %>
                <tr>
                  <td><code><%= record[:name] %></code></td>
                  <td><code><%= record[:value] %></code></td>
                  <td>
                    <button type="button" class="btn btn--plain btn--medium" data-controller="clipboard"
                      data-clipboard-text-value="<%= record[:value] %>" data-action="clipboard#copy"
                      aria-label="Copy CNAME value">
                      <%= icon_tag "copy-paste" %>
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </article>
    <% end %>
  <% else %>
    <p>No domains yet. Add the domain you send from to verify it with SES.</p>
  <% end %>
<% else %>
  <p>No active project yet.</p>
<% end %>
```

Create `app/assets/stylesheets/settings.css` (shared by domains, sources, webhooks, API keys, templates, onboarding views in this phase):

```css
@layer modules {
  .settings-card {
    background-color: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 0.75em;
    margin-block-end: var(--block-space);
    padding: var(--block-space) var(--inline-space);
  }

  .settings-card__header {
    align-items: center;
    display: flex;
    flex-wrap: wrap;
    gap: var(--inline-space);
  }

  .settings-card__header h2 {
    font-size: var(--text-medium);
    margin-block: 0;
  }

  .settings-table {
    border-collapse: collapse;
    inline-size: 100%;
    margin-block-start: var(--block-space);
  }

  .settings-table th,
  .settings-table td {
    border-block-end: 1px solid var(--color-border);
    padding-block: calc(var(--block-space) / 2);
    padding-inline-end: var(--inline-space);
    text-align: start;
  }

  .inline-form {
    align-items: center;
    display: flex;
    gap: var(--inline-space);
    margin-block-end: var(--block-space);
  }

  .secret-reveal {
    background-color: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 0.75em;
    padding: var(--block-space) var(--inline-space);
  }

  .secret-reveal code {
    font-size: var(--text-medium);
    overflow-wrap: anywhere;
    user-select: all;
  }
}
```

If `--text-medium` or another token referenced above does not exist in `base.css`, use the closest existing token instead of inventing raw values — check `base.css` first.

In `app/views/layouts/_nav.html.erb`, add after the Suppressions link (same `nav__link` + `aria-current` pattern as the existing entries):

```erb
  <%= link_to "Domains", domains_path, class: "nav__link",
        aria: { current: current_page?(domains_path) ? "page" : nil } %>
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bin/rails test test/controllers/domains_controller_test.rb`
Expected: PASS

- [ ] **Step 7: Verify light + dark rendering**

Run `bin/dev`, visit `/domains`, add a domain, confirm the DKIM table and pills read correctly in both themes (toggle `html[data-theme]`).

- [ ] **Step 8: Full suite + rubocop, then commit**

Run: `bin/rails test && bin/rubocop`

```bash
git add config/routes.rb app/controllers/domains_controller.rb app/controllers/domains app/views/domains app/views/layouts/_nav.html.erb app/assets/stylesheets/settings.css test/controllers/domains_controller_test.rb
git commit -m "feat: domains dashboard with DKIM records and DNS re-check"
```

---

### Task 3: `Source::Quota` — quota sync, staleness, complaint breaker

**Files:**
- Create: `app/models/source/quota.rb`
- Modify: `app/models/source.rb` (include)
- Modify: `test/fixtures/sources.yml` (fresh quota timestamps)
- Create: `test/models/source/quota_test.rb`

**Interfaces:**
- Consumes: `Source#ses_client`, `source.emails`, `EmailEvent`.
- Produces: `Source#sync_quota → true/false` (SES `get_account` → `last_quota` json + `last_quota_checked_at`); `Source#quota_stale?` / `Source#quota_fresh?` (6-hour TTL); `Source#complaint_rate_exceeded?` (≥100 sends in 30 days AND ≥0.1% complaint rate); `Source.sync_all_quotas` (Phase 6's `SyncQuotasJob` delegates to this). Constants `Source::Quota::QUOTA_TTL`, `COMPLAINT_BREAKER_MINIMUM_SENDS`, `COMPLAINT_BREAKER_RATE`.

- [ ] **Step 1: Freshen the source fixtures**

Existing submission tests must not trip the staleness guardrail (wired in Task 4). In `test/fixtures/sources.yml`, add to BOTH `acme_production` and `globex_production`:

```yaml
  last_quota_checked_at: <%= 1.hour.ago %>
  last_quota:
    max_24_hour_send: 50000.0
    max_send_rate: 14.0
    sent_last_24_hours: 120.0
    sending_enabled: true
    production_access: true
```

- [ ] **Step 2: Write the failing tests**

Create `test/models/source/quota_test.rb`:

```ruby
require "test_helper"

class Source::QuotaTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    @source = sources(:acme_production)
    @source.ses_client = Aws::SESV2::Client.new(stub_responses: true)
  end

  test "sync_quota stores the account quota and stamps the check time" do
    @source.ses_client.stub_responses(:get_account,
      send_quota: { max_24_hour_send: 200.0, max_send_rate: 1.0, sent_last_24_hours: 7.0 },
      sending_enabled: true, production_access_enabled: false)
    @source.update!(last_quota: nil, last_quota_checked_at: nil)

    assert @source.sync_quota
    assert_equal 200.0, @source.last_quota["max_24_hour_send"]
    assert_equal 7.0, @source.last_quota["sent_last_24_hours"]
    assert_equal false, @source.last_quota["production_access"]
    assert @source.last_quota_checked_at.present?
  end

  test "sync_quota returns false and keeps the stale stamp on SES errors" do
    @source.ses_client.stub_responses(:get_account, "TooManyRequestsException")
    @source.update!(last_quota_checked_at: nil)

    assert_not @source.sync_quota
    assert_nil @source.reload.last_quota_checked_at
  end

  test "quota_stale? uses the six hour TTL" do
    @source.update!(last_quota_checked_at: nil)
    assert @source.quota_stale?

    @source.update!(last_quota_checked_at: 7.hours.ago)
    assert @source.quota_stale?
    assert_not @source.quota_fresh?

    @source.update!(last_quota_checked_at: 5.hours.ago)
    assert @source.quota_fresh?
  end

  test "sync_all_quotas refreshes every source" do
    Source.update_all(last_quota_checked_at: nil)

    Source.sync_all_quotas

    assert Source.all.all? { |source| source.last_quota_checked_at.present? }
  end

  test "complaint breaker stays open under the minimum send volume" do
    wipe_send_domain
    insert_emails(@source, count: 99)
    record_complaint(@source.emails.first)

    assert_not @source.complaint_rate_exceeded?
  end

  test "complaint breaker trips at or above 0.1 percent of 100+ sends" do
    wipe_send_domain
    insert_emails(@source, count: 100)
    record_complaint(@source.emails.first)

    assert @source.complaint_rate_exceeded?
  end

  test "complaint breaker ignores complaints outside the 30 day window" do
    wipe_send_domain
    insert_emails(@source, count: 100)
    record_complaint(@source.emails.first, occurred_at: 31.days.ago)

    assert_not @source.complaint_rate_exceeded?
  end

  private
    def insert_emails(source, count:)
      now = Time.current
      Email.insert_all(count.times.map do |index|
        { project_id: source.project_id, workspace_id: source.workspace_id, source_id: source.id,
          from: "hello@acme.com", subject: "Bulk #{index}", status: "sent",
          public_id: "em_breaker_#{index}_#{SecureRandom.alphanumeric(8)}",
          created_at: now, updated_at: now }
      end)
    end

    def record_complaint(email, occurred_at: Time.current)
      email.events.create!(event_type: "complaint", occurred_at: occurred_at, payload: {})
    end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/models/source/quota_test.rb`
Expected: FAIL (undefined method `sync_quota`)

- [ ] **Step 4: Implement the concern**

Create `app/models/source/quota.rb`:

```ruby
module Source::Quota
  extend ActiveSupport::Concern

  QUOTA_TTL = 6.hours
  COMPLAINT_BREAKER_WINDOW = 30.days
  COMPLAINT_BREAKER_MINIMUM_SENDS = 100
  COMPLAINT_BREAKER_RATE = 0.1 # percent

  class_methods do
    def sync_all_quotas
      find_each(&:sync_quota)
    end
  end

  def sync_quota
    response = ses_client.get_account
    update!(last_quota_checked_at: Time.current, last_quota: {
      "max_24_hour_send" => response.send_quota&.max_24_hour_send,
      "max_send_rate" => response.send_quota&.max_send_rate,
      "sent_last_24_hours" => response.send_quota&.sent_last_24_hours,
      "sending_enabled" => response.sending_enabled,
      "production_access" => response.production_access_enabled
    })
    true
  rescue Aws::SESV2::Errors::ServiceError
    false
  end

  def quota_stale?
    last_quota_checked_at.nil? || last_quota_checked_at < QUOTA_TTL.ago
  end

  def quota_fresh?
    !quota_stale?
  end

  def complaint_rate_exceeded?
    sends = emails.where(created_at: COMPLAINT_BREAKER_WINDOW.ago..).count

    if sends < COMPLAINT_BREAKER_MINIMUM_SENDS
      false
    else
      complaints = EmailEvent.where(email_id: emails.select(:id), event_type: "complaint",
        occurred_at: COMPLAINT_BREAKER_WINDOW.ago..).distinct.count(:email_id)
      complaints * 100.0 / sends >= COMPLAINT_BREAKER_RATE
    end
  end
end
```

In `app/models/source.rb`, add at the top of the class body:

```ruby
  include Quota
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/models/source/quota_test.rb`
Expected: PASS

- [ ] **Step 6: Full suite + rubocop, then commit**

Run: `bin/rails test && bin/rubocop`

```bash
git add app/models/source.rb app/models/source/quota.rb test/fixtures/sources.yml test/models/source
git commit -m "feat: Source::Quota — quota sync, staleness TTL, complaint breaker"
```

---

### Task 4: Wire the `EmailSubmission` guardrails

**Files:**
- Modify: `app/models/email_submission.rb` (replace the three seam predicates)
- Modify: `test/models/email_submission_test.rb` (new guardrail tests)
- Modify: `test/controllers/test_emails_controller_test.rb` (one test uses an unverifiable from)

**Interfaces:**
- Consumes: `Domain.verifies?(project, address)` (Task 1), `Source#quota_stale?` / `#sync_quota` / `#quota_fresh?` / `#complaint_rate_exceeded?` (Task 3).
- Produces: `EmailSubmission` now rejects — with 422 via the existing error paths — sends from unverified domains ("domain is not verified"), sends when the quota is stale and cannot be refreshed ("sending quota information is stale"), and sends while the complaint breaker is tripped ("sending is paused due to complaint rate"). Resends (`Email#resend`) inherit all three automatically because they rebuild an `EmailSubmission`.

- [ ] **Step 1: Write the failing tests**

Add to `test/models/email_submission_test.rb` (match the file's existing helper style for building valid submissions — reuse its builder if one exists; the literal form below works regardless):

```ruby
  test "guardrail: rejects a from address on an unverified domain" do
    submission = EmailSubmission.new(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@unverified.io", to: [ "user@example.com" ], subject: "Hi", text: "Hi")

    assert_not submission.valid?
    assert_includes submission.errors.full_messages.join, "domain is not verified"
  end

  test "guardrail: accepts a from address on a subdomain of a verified domain" do
    submission = EmailSubmission.new(project: projects(:acme_default), source: sources(:acme_production),
      from: "no-reply@mail.acme.com", to: [ "user@example.com" ], subject: "Hi", text: "Hi")

    assert submission.valid?
  end

  test "guardrail: a stale quota is refreshed best-effort before rejecting" do
    source = sources(:acme_production)
    source.update!(last_quota_checked_at: 7.hours.ago)
    source.ses_client = Aws::SESV2::Client.new(stub_responses: true)
    source.ses_client.stub_responses(:get_account,
      send_quota: { max_24_hour_send: 200.0, max_send_rate: 1.0, sent_last_24_hours: 7.0 })

    submission = EmailSubmission.new(project: projects(:acme_default), source: source,
      from: "hello@acme.com", to: [ "user@example.com" ], subject: "Hi", text: "Hi")

    assert submission.valid?
    assert source.quota_fresh?
  end

  test "guardrail: rejects when the quota is stale and the refresh fails" do
    source = sources(:acme_production)
    source.update!(last_quota_checked_at: 7.hours.ago)
    source.ses_client = Aws::SESV2::Client.new(stub_responses: true)
    source.ses_client.stub_responses(:get_account, "TooManyRequestsException")

    submission = EmailSubmission.new(project: projects(:acme_default), source: source,
      from: "hello@acme.com", to: [ "user@example.com" ], subject: "Hi", text: "Hi")

    assert_not submission.valid?
    assert_includes submission.errors.full_messages.join, "quota information is stale"
  end

  test "guardrail: rejects while the complaint breaker is tripped" do
    source = sources(:acme_production)

    source.stub(:complaint_rate_exceeded?, true) do
      submission = EmailSubmission.new(project: projects(:acme_default), source: source,
        from: "hello@acme.com", to: [ "user@example.com" ], subject: "Hi", text: "Hi")

      assert_not submission.valid?
      assert_includes submission.errors.full_messages.join, "paused due to complaint rate"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/email_submission_test.rb`
Expected: the five new tests FAIL (seams still return the permissive defaults)

- [ ] **Step 3: Replace the seam predicates**

In `app/models/email_submission.rb`, `validate_guardrails` needs a guard now that the predicates dereference `project`/`source` (both can be nil — presence validation reports that separately):

```ruby
    def validate_guardrails
      return if project.nil? || source.nil?

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
```

And replace the three seam methods at the bottom of the file (delete the seam comment):

```ruby
    def from_domain_verified?
      Domain.verifies?(project, from)
    end

    def quota_fresh?
      if source.quota_stale?
        source.sync_quota
      end
      source.quota_fresh?
    end

    def complaint_breaker_tripped?
      source.complaint_rate_exceeded?
    end
```

- [ ] **Step 4: Fix the one test using an unverifiable from-domain**

In `test/controllers/test_emails_controller_test.rb`, the test posting `from: "a@b.c"` now fails the domain guardrail. Change that test's params to `from: "hello@acme.com"` (keep everything else). Its assertion is about the redirect-after-queue behavior, not the address.

- [ ] **Step 5: Run the full suite and fix any residual from-domain fallout**

Run: `bin/rails test`
Expected: green. If any other test builds a submission from a domain not covered by `domains.yml` (`acme.com`, `globex.com` are verified fixtures), point it at a fixture-verified domain — do not add more verified fixtures unless a test is specifically about multiple domains.

- [ ] **Step 6: Rubocop, then commit**

Run: `bin/rubocop`

```bash
git add app/models/email_submission.rb test/models/email_submission_test.rb test/controllers/test_emails_controller_test.rb
git commit -m "feat: wire EmailSubmission guardrails — verified domain, quota freshness, complaint breaker"
```

---

### Task 5: Sources dashboard — `SourcesController` + `Sources::QuotaSyncsController`

**Files:**
- Create: `app/controllers/sources_controller.rb`
- Create: `app/controllers/sources/quota_syncs_controller.rb`
- Create: `app/views/sources/index.html.erb`, `app/views/sources/new.html.erb`, `app/views/sources/edit.html.erb`, `app/views/sources/_form.html.erb`
- Modify: `config/routes.rb`, `app/views/layouts/_nav.html.erb`
- Create: `test/controllers/sources_controller_test.rb`

**Interfaces:**
- Consumes: `Source` validations, `Source#sync_quota` (Task 3), `ses_webhooks_url(webhook_token:)` route helper, `authorize_capability! :manage_domains` (sources are part of the identities/setup section — no dedicated capability exists in `Workspace::Roles`).
- Produces: routes `sources_path`, `new_source_path`, `edit_source_path`, `source_quota_sync_path` (`POST /sources/:source_id/quota_sync`). Used by the onboarding wizard (Task 14).

- [ ] **Step 1: Write the failing controller tests**

Create `test/controllers/sources_controller_test.rb`:

```ruby
require "test_helper"

class SourcesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
  end

  test "index lists the project's sources with their webhook URLs" do
    get sources_url

    assert_response :success
    assert_match "production", response.body
    assert_match sources(:acme_production).webhook_token, response.body
    assert_no_match sources(:globex_production).webhook_token, response.body
  end

  test "create adds a source to the current project" do
    assert_difference -> { projects(:acme_default).sources.count }, +1 do
      post sources_url, params: { source: { name: "Staging", environment: "staging",
        region: "eu-west-1", default_from: "hello@acme.com", retention_days: 30,
        aws_access_key_id: "AKIA123", aws_secret_access_key: "secret123" } }
    end

    assert_redirected_to sources_url
  end

  test "create rejects a duplicate environment" do
    post sources_url, params: { source: { environment: "production", region: "eu-west-1" } }

    assert_response :unprocessable_entity
  end

  test "update keeps existing credentials when the fields are left blank" do
    source = sources(:acme_production)
    original_key = source.aws_secret_access_key

    patch source_url(source), params: { source: { name: "Renamed", aws_access_key_id: "",
      aws_secret_access_key: "" } }

    assert_redirected_to sources_url
    source.reload
    assert_equal "Renamed", source.name
    assert_equal original_key, source.aws_secret_access_key
  end

  test "quota sync refreshes the quota" do
    sources(:acme_production).update!(last_quota_checked_at: nil)

    post source_quota_sync_url(sources(:acme_production))

    assert_redirected_to sources_url
    assert sources(:acme_production).reload.last_quota_checked_at.present?
  end

  test "cross-tenant sources 404" do
    patch source_url(sources(:globex_production)), params: { source: { name: "Hacked" } }
    assert_response :not_found
  end

  test "mutations require the manage_domains capability" do
    sign_in_as users(:read_only)

    post sources_url, params: { source: { environment: "staging", region: "eu-west-1" } }
    assert_response :forbidden

    post source_quota_sync_url(sources(:acme_production))
    assert_response :forbidden
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/sources_controller_test.rb`
Expected: FAIL (no route)

- [ ] **Step 3: Add routes**

In `config/routes.rb`, after the domains block:

```ruby
  resources :sources, only: %i[ index new create edit update ] do
    scope module: :sources do
      resource :quota_sync, only: :create
    end
  end
```

- [ ] **Step 4: Implement the controllers**

Create `app/controllers/sources_controller.rb`:

```ruby
class SourcesController < ApplicationController
  include RequiresProject

  skip_before_action :require_project, only: :index
  before_action -> { authorize_capability! :manage_domains }, except: :index
  before_action :set_source, only: %i[ edit update ]

  def index
    if Current.project
      @sources = Current.project.sources.order(:environment)
    end
  end

  def new
    @source = Current.project.sources.new
  end

  def create
    @source = Current.project.sources.new(source_params)

    if @source.save
      redirect_to sources_path, notice: "Source added."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @source.update(source_params)
      redirect_to sources_path, notice: "Source updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    def set_source
      @source = Current.project.sources.find(params[:id])
    end

    def source_params
      params.require(:source).permit(:name, :environment, :region, :default_from,
        :configuration_set, :retention_days, :aws_access_key_id, :aws_secret_access_key)
        .tap do |permitted|
          %i[ aws_access_key_id aws_secret_access_key ].each do |credential|
            if permitted[credential].blank?
              permitted.delete(credential)
            end
          end
        end
    end
end
```

Create `app/controllers/sources/quota_syncs_controller.rb`:

```ruby
class Sources::QuotaSyncsController < ApplicationController
  include RequiresProject

  before_action -> { authorize_capability! :manage_domains }

  def create
    source = Current.project.sources.find(params[:source_id])

    if source.sync_quota
      redirect_to sources_path, notice: "Quota refreshed."
    else
      redirect_to sources_path, alert: "Could not reach SES to refresh the quota."
    end
  end
end
```

- [ ] **Step 5: Build the views and nav link**

Create `app/views/sources/_form.html.erb`:

```erb
<%= form_with model: source do |form| %>
  <% if source.errors.any? %>
    <div class="flash flash--alert"><%= source.errors.full_messages.to_sentence %></div>
  <% end %>

  <div class="form-row">
    <%= form.label :name %>
    <%= form.text_field :name, class: "input" %>
  </div>
  <div class="form-row">
    <%= form.label :environment %>
    <%= form.text_field :environment, class: "input", required: true %>
  </div>
  <div class="form-row">
    <%= form.label :region %>
    <%= form.text_field :region, class: "input", required: true %>
  </div>
  <div class="form-row">
    <%= form.label :default_from, "Default from address" %>
    <%= form.email_field :default_from, class: "input" %>
  </div>
  <div class="form-row">
    <%= form.label :configuration_set, "SES configuration set" %>
    <%= form.text_field :configuration_set, class: "input" %>
  </div>
  <div class="form-row">
    <%= form.label :retention_days %>
    <%= form.number_field :retention_days, class: "input", min: 1 %>
  </div>
  <div class="form-row">
    <%= form.label :aws_access_key_id, "AWS access key ID" %>
    <%= form.text_field :aws_access_key_id, class: "input", value: "",
          placeholder: source.persisted? ? "Unchanged unless filled in" : nil %>
  </div>
  <div class="form-row">
    <%= form.label :aws_secret_access_key, "AWS secret access key" %>
    <%= form.password_field :aws_secret_access_key, class: "input", value: "",
          placeholder: source.persisted? ? "Unchanged unless filled in" : nil %>
  </div>

  <%= form.submit source.persisted? ? "Update source" : "Add source", class: "btn btn--primary btn--large" %>
<% end %>
```

(Reuse the existing form-row / flash markup conventions from `test_emails/new.html.erb` if they differ — the point is `.input` fields, labels, and one primary submit.)

Create `app/views/sources/new.html.erb`:

```erb
<% content_for :title, "New source" %>
<h1>New source</h1>
<%= render "form", source: @source %>
```

Create `app/views/sources/edit.html.erb`:

```erb
<% content_for :title, "Edit source" %>
<h1>Edit source</h1>
<%= render "form", source: @source %>
```

Create `app/views/sources/index.html.erb`:

```erb
<% content_for :title, "Sources" %>

<% if Current.project %>
  <header class="page-header">
    <h1>Sources</h1>
    <% if Current.workspace.capability?(Current.user, :manage_domains) %>
      <%= link_to "New source", new_source_path, class: "btn btn--primary btn--medium" %>
    <% end %>
  </header>

  <% if @sources.any? %>
    <% @sources.each do |source| %>
      <article class="settings-card">
        <header class="settings-card__header">
          <h2><%= source.name.presence || source.environment %></h2>
          <span><%= source.environment %> · <%= source.region %></span>
          <% if Current.workspace.capability?(Current.user, :manage_domains) %>
            <%= link_to "Edit", edit_source_path(source), class: "btn btn--secondary btn--medium" %>
            <%= button_to "Sync quota", source_quota_sync_path(source), class: "btn btn--secondary btn--medium" %>
          <% end %>
        </header>

        <dl class="settings-card__facts">
          <dt>SNS webhook URL</dt>
          <dd>
            <code><%= ses_webhooks_url(webhook_token: source.webhook_token) %></code>
            <button type="button" class="btn btn--plain btn--medium" data-controller="clipboard"
              data-clipboard-text-value="<%= ses_webhooks_url(webhook_token: source.webhook_token) %>"
              data-action="clipboard#copy" aria-label="Copy webhook URL">
              <%= icon_tag "copy-paste" %>
            </button>
          </dd>

          <% if source.last_quota.present? %>
            <dt>Quota</dt>
            <dd>
              <%= source.last_quota["sent_last_24_hours"].to_i %> / <%= source.last_quota["max_24_hour_send"].to_i %>
              sent in 24h · checked <%= time_ago_in_words(source.last_quota_checked_at) %> ago
            </dd>
          <% end %>
        </dl>
      </article>
    <% end %>
  <% else %>
    <p>No sources yet. A source holds the SES credentials Departures sends with.</p>
  <% end %>
<% else %>
  <p>No active project yet.</p>
<% end %>
```

Add to `app/assets/stylesheets/settings.css` inside the existing `@layer modules` block:

```css
  .settings-card__facts {
    display: grid;
    gap: calc(var(--block-space) / 2) var(--inline-space);
    grid-template-columns: max-content 1fr;
    margin-block: var(--block-space) 0;
  }

  .settings-card__facts dt {
    color: var(--color-ink-lighter);
  }
```

Add the nav link in `app/views/layouts/_nav.html.erb` after Domains:

```erb
  <%= link_to "Sources", sources_path, class: "nav__link",
        aria: { current: current_page?(sources_path) ? "page" : nil } %>
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bin/rails test test/controllers/sources_controller_test.rb`
Expected: PASS

- [ ] **Step 7: Full suite + rubocop, verify light/dark, then commit**

Run: `bin/rails test && bin/rubocop`

```bash
git add config/routes.rb app/controllers/sources_controller.rb app/controllers/sources app/views/sources app/views/layouts/_nav.html.erb app/assets/stylesheets/settings.css test/controllers/sources_controller_test.rb
git commit -m "feat: sources dashboard with credential management and manual quota sync"
```

---

### Task 6: `WebhookEndpoint` model

**Files:**
- Create: `db/migrate/<timestamp>_create_webhook_endpoints.rb`
- Create: `app/models/webhook_endpoint.rb`
- Create: `test/fixtures/webhook_endpoints.yml`
- Create: `test/models/webhook_endpoint_test.rb`
- Modify: `app/models/project.rb`, `test/test_helper.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces: `WebhookEndpoint` with `scope :active`, `#subscribed_to?(event_type) → bool`, `#success_rate → Float|nil`, `EVENT_TYPES` constant (the `Email::SesEvent#event_type` vocabulary: `send delivery open click bounce complaint delivery_delay reject rendering_failure subscription`), auto-generated encrypted `whsec_` secret, `project.webhook_endpoints`. `has_many :deliveries` is declared in Task 7.

- [ ] **Step 1: Generate the migration**

Run: `bin/rails generate migration CreateWebhookEndpoints`

```ruby
class CreateWebhookEndpoints < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_endpoints do |t|
      t.references :project, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.string :url, null: false
      t.string :secret
      t.json :events, default: [], null: false
      t.boolean :active, default: true, null: false

      t.timestamps
    end
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write fixtures**

Create `test/fixtures/webhook_endpoints.yml`:

```yaml
acme_all:
  project: acme_default
  workspace: acme
  url: https://hooks.acme.com/departures
  secret: whsec_acmeTestSecret000000000000000
  events: [ "delivery", "bounce", "complaint", "open", "click" ]
  active: true

acme_inactive:
  project: acme_default
  workspace: acme
  url: https://old-hooks.acme.com/departures
  secret: whsec_acmeOldSecret0000000000000000
  events: [ "bounce" ]
  active: false

globex_bounces:
  project: globex_default
  workspace: globex
  url: https://hooks.globex.com/departures
  secret: whsec_globexSecret000000000000000
  events: [ "bounce", "complaint" ]
  active: true
```

- [ ] **Step 3: Write the failing tests**

Create `test/models/webhook_endpoint_test.rb`:

```ruby
require "test_helper"

class WebhookEndpointTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "creating an endpoint generates an encrypted whsec_ secret" do
    endpoint = projects(:acme_default).webhook_endpoints.create!(url: "https://example.com/hook",
      events: %w[ bounce ])

    assert_match(/\Awhsec_[A-Za-z0-9]{32}\z/, endpoint.secret)
    assert_equal workspaces(:acme), endpoint.workspace
    assert endpoint.active
  end

  test "url must be https" do
    endpoint = projects(:acme_default).webhook_endpoints.build(url: "http://example.com/hook",
      events: %w[ bounce ])

    assert_not endpoint.valid?
    assert endpoint.errors[:url].any?
  end

  test "events must be a non-empty subset of the known types" do
    endpoint = projects(:acme_default).webhook_endpoints.build(url: "https://example.com/hook", events: [])
    assert_not endpoint.valid?

    endpoint.events = %w[ bounce made_up ]
    assert_not endpoint.valid?

    endpoint.events = %w[ bounce complaint ]
    assert endpoint.valid?
  end

  test "events setter drops the blanks checkbox forms submit" do
    endpoint = projects(:acme_default).webhook_endpoints.build(url: "https://example.com/hook",
      events: [ "", "bounce" ])

    assert_equal %w[ bounce ], endpoint.events
  end

  test "subscribed_to? and the active scope drive fan-out selection" do
    assert webhook_endpoints(:acme_all).subscribed_to?("bounce")
    assert_not webhook_endpoints(:acme_all).subscribed_to?("reject")

    assert_includes projects(:acme_default).webhook_endpoints.active, webhook_endpoints(:acme_all)
    assert_not_includes projects(:acme_default).webhook_endpoints.active, webhook_endpoints(:acme_inactive)
  end
end
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `bin/rails test test/models/webhook_endpoint_test.rb`
Expected: FAIL (uninitialized constant)

- [ ] **Step 5: Implement the model**

Create `app/models/webhook_endpoint.rb`:

```ruby
class WebhookEndpoint < ApplicationRecord
  EVENT_TYPES = %w[ send delivery open click bounce complaint delivery_delay
                    reject rendering_failure subscription ].freeze

  belongs_to :project
  belongs_to :workspace, default: -> { project.workspace }

  encrypts :secret

  scope :active, -> { where(active: true) }

  validates :url, presence: true, format: { with: %r{\Ahttps://}, message: "must be an https URL" }
  validate :validate_events

  before_create :assign_secret

  def events=(value)
    super(Array(value).map(&:to_s).reject(&:blank?))
  end

  def subscribed_to?(event_type)
    events.include?(event_type.to_s)
  end

  def success_rate
    settled = deliveries.where.not(status: "pending").count

    if settled.zero?
      nil
    else
      (deliveries.succeeded.count * 100.0 / settled).round(1)
    end
  end

  private
    def validate_events
      if events.blank?
        errors.add(:events, "must include at least one event type")
      elsif (events - EVENT_TYPES).any?
        errors.add(:events, "contains unknown event types: #{(events - EVENT_TYPES).join(", ")}")
      end
    end

    def assign_secret
      self.secret ||= "whsec_#{SecureRandom.alphanumeric(32)}"
    end
end
```

`success_rate` references the `deliveries` association, which Task 7 declares along with the `webhook_deliveries` table. That is fine — Ruby resolves `deliveries` at call time, and nothing calls `success_rate` until Task 9's views/tests. Do not call it in this task's tests.

In `app/models/project.rb`, add:

```ruby
  has_many :webhook_endpoints, dependent: :destroy
```

In `test/test_helper.rb`, inside `wipe_workspace_records`, add before `Project.delete_all`:

```ruby
      WebhookEndpoint.delete_all
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bin/rails test test/models/webhook_endpoint_test.rb`
Expected: PASS

- [ ] **Step 7: Full suite + rubocop, then commit**

Run: `bin/rails test && bin/rubocop`

```bash
git add db/migrate db/schema.rb app/models/webhook_endpoint.rb app/models/project.rb test/fixtures/webhook_endpoints.yml test/models/webhook_endpoint_test.rb test/test_helper.rb
git commit -m "feat: WebhookEndpoint model with encrypted whsec_ secrets and event subscriptions"
```

---

### Task 7: `WebhookDelivery` + `DeliverWebhookJob`

**Files:**
- Create: `db/migrate/<timestamp>_create_webhook_deliveries.rb`
- Create: `app/models/webhook_delivery.rb`
- Create: `app/jobs/deliver_webhook_job.rb`
- Modify: `app/models/webhook_endpoint.rb` (association)
- Modify: `test/test_helper.rb`
- Create: `test/models/webhook_delivery_test.rb`
- Create: `test/jobs/deliver_webhook_job_test.rb`

**Interfaces:**
- Consumes: `WebhookEndpoint#secret`, `WebhookEndpoint#url`.
- Produces: `WebhookDelivery#deliver → true` (raises `WebhookDelivery::DeliveryError` on any failure so Solid Queue retries; records `attempts`/`http_status`/`latency_ms`/`response_body`/`last_attempted_at` per attempt); `#deliver_later`; `#mark_failed`; `#signature(timestamp, body) → String` (hex HMAC-SHA256 of `"{timestamp}.{body}"`); header `Departures-Signature: t={ts},v1={sig}`; enum `pending/succeeded/failed` with scopes; `webhook_endpoint.deliveries`. `DeliverWebhookJob` on queue `:webhooks`, 3 attempts, marks failed on exhaustion.

- [ ] **Step 1: Generate the migration**

Run: `bin/rails generate migration CreateWebhookDeliveries`

```ruby
class CreateWebhookDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_deliveries do |t|
      t.references :webhook_endpoint, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.references :email, foreign_key: { on_delete: :nullify }
      t.string :event_type, null: false
      t.json :payload, default: {}, null: false
      t.string :status, default: "pending", null: false
      t.integer :attempts, default: 0, null: false
      t.integer :http_status
      t.integer :latency_ms
      t.string :response_body
      t.datetime :last_attempted_at

      t.timestamps
    end

    add_index :webhook_deliveries, %i[ webhook_endpoint_id created_at ]
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write the failing model tests**

Create `test/models/webhook_delivery_test.rb`:

```ruby
require "test_helper"

class WebhookDeliveryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Current.session = sessions(:owner)
    @delivery = webhook_endpoints(:acme_all).deliveries.create!(event_type: "bounce",
      payload: { "event" => "bounce" })
  end

  test "workspace defaults from the endpoint" do
    assert_equal workspaces(:acme), @delivery.workspace
    assert @delivery.pending?
  end

  test "a 2xx response marks the delivery succeeded and records the attempt" do
    @delivery.stub(:post_payload, http_response(Net::HTTPOK, "200", "ok")) do
      assert @delivery.deliver
    end

    assert @delivery.succeeded?
    assert_equal 1, @delivery.attempts
    assert_equal 200, @delivery.http_status
    assert_equal "ok", @delivery.response_body
    assert @delivery.latency_ms.present?
    assert @delivery.last_attempted_at.present?
  end

  test "a non-2xx response records the attempt and raises for retry" do
    @delivery.stub(:post_payload, http_response(Net::HTTPInternalServerError, "500", "boom")) do
      assert_raises WebhookDelivery::DeliveryError do
        @delivery.deliver
      end
    end

    assert @delivery.pending?, "stays pending so the job retry can run again"
    assert_equal 1, @delivery.attempts
    assert_equal 500, @delivery.http_status
    assert_equal "boom", @delivery.response_body
  end

  test "network errors record the attempt and raise for retry" do
    raising = -> { raise SocketError, "getaddrinfo failed" }

    @delivery.stub(:post_payload, raising) do
      assert_raises WebhookDelivery::DeliveryError do
        @delivery.deliver
      end
    end

    assert @delivery.pending?
    assert_equal 1, @delivery.attempts
    assert_nil @delivery.http_status
    assert_match "getaddrinfo", @delivery.response_body
  end

  test "a settled delivery does not post again" do
    @delivery.update!(status: "succeeded")

    never_called = -> { flunk "must not post a settled delivery" }
    @delivery.stub(:post_payload, never_called) do
      assert_not @delivery.deliver
    end
  end

  test "signature is the documented HMAC over timestamp dot body" do
    body = { "event" => "bounce" }.to_json
    expected = OpenSSL::HMAC.hexdigest("SHA256", webhook_endpoints(:acme_all).secret, "1700000000.#{body}")

    assert_equal expected, @delivery.signature(1_700_000_000, body)
  end

  test "response bodies are truncated" do
    @delivery.stub(:post_payload, http_response(Net::HTTPOK, "200", "x" * 5_000)) do
      @delivery.deliver
    end

    assert_operator @delivery.response_body.length, :<=, 1_000
  end

  test "deliver_later enqueues on the webhooks queue" do
    assert_enqueued_with(job: DeliverWebhookJob, args: [ @delivery ], queue: "webhooks") do
      @delivery.deliver_later
    end
  end

  private
    def http_response(klass, code, body)
      response = klass.new("1.1", code, "")
      response.instance_variable_set(:@read, true)
      response.instance_variable_set(:@body, body)
      response
    end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/models/webhook_delivery_test.rb`
Expected: FAIL (uninitialized constant)

- [ ] **Step 4: Implement the model and job**

Create `app/models/webhook_delivery.rb`:

```ruby
class WebhookDelivery < ApplicationRecord
  class DeliveryError < StandardError; end

  MAX_RESPONSE_BODY = 1_000
  TIMEOUT = 5.seconds

  belongs_to :webhook_endpoint
  belongs_to :workspace, default: -> { webhook_endpoint.workspace }
  belongs_to :email, optional: true

  enum :status, %w[ pending succeeded failed ].index_by(&:itself), default: "pending", validate: true

  scope :reverse_chronologically, -> { order(created_at: :desc, id: :desc) }

  validates :event_type, presence: true

  # Solid Queue delivers at least once — a settled delivery must never post again.
  def deliver
    if pending?
      attempt
    else
      false
    end
  end

  def deliver_later
    DeliverWebhookJob.perform_later(self)
  end

  def mark_failed
    update!(status: "failed")
  end

  def signature(timestamp, body)
    OpenSSL::HMAC.hexdigest("SHA256", webhook_endpoint.secret, "#{timestamp}.#{body}")
  end

  private
    def attempt
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      begin
        response = post_payload
      rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, EOFError => error
        record_attempt(http_status: nil, body: error.message, started_at: started_at)
        raise DeliveryError, error.message
      end

      record_attempt(http_status: response.code.to_i, body: response.body, started_at: started_at)

      if response.is_a?(Net::HTTPSuccess)
        update!(status: "succeeded")
        true
      else
        raise DeliveryError, "endpoint responded with HTTP #{response.code}"
      end
    end

    def post_payload
      body = payload.to_json
      timestamp = Time.current.to_i
      uri = URI.parse(webhook_endpoint.url)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.is_a?(URI::HTTPS)
      http.open_timeout = TIMEOUT.to_i
      http.read_timeout = TIMEOUT.to_i

      request = Net::HTTP::Post.new(uri.request_uri,
        "Content-Type" => "application/json",
        "User-Agent" => "Departures-Webhooks",
        "Departures-Signature" => "t=#{timestamp},v1=#{signature(timestamp, body)}")
      request.body = body

      http.request(request)
    end

    def record_attempt(http_status:, body:, started_at:)
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1_000).round

      update!(attempts: attempts + 1, http_status: http_status,
        response_body: body.to_s.truncate(MAX_RESPONSE_BODY),
        latency_ms: elapsed_ms, last_attempted_at: Time.current)
    end
end
```

Create `app/jobs/deliver_webhook_job.rb`:

```ruby
class DeliverWebhookJob < ApplicationJob
  queue_as :webhooks

  retry_on WebhookDelivery::DeliveryError, wait: :polynomially_longer, attempts: 3 do |job, _error|
    job.arguments.first.mark_failed
  end

  def perform(webhook_delivery)
    webhook_delivery.deliver
  end
end
```

In `app/models/webhook_endpoint.rb`, add below the `belongs_to` lines:

```ruby
  has_many :deliveries, class_name: "WebhookDelivery", dependent: :destroy
```

In `test/test_helper.rb`, inside `wipe_workspace_records`, add before `WebhookEndpoint.delete_all`:

```ruby
      WebhookDelivery.delete_all
```

- [ ] **Step 5: Write the job test**

Retry exhaustion through the real ActiveJob retry machinery is awkward to drive in-process, so test the queue/delegation wiring and the exhaustion handler (`mark_failed`) directly. Create `test/jobs/deliver_webhook_job_test.rb`:

```ruby
require "test_helper"

class DeliverWebhookJobTest < ActiveJob::TestCase
  setup do
    Current.session = sessions(:owner)
    @delivery = webhook_endpoints(:acme_all).deliveries.create!(event_type: "bounce",
      payload: { "event" => "bounce" })
  end

  test "runs on the webhooks queue and delegates to deliver" do
    assert_equal "webhooks", DeliverWebhookJob.new(@delivery).queue_name

    @delivery.stub(:deliver, true) do
      DeliverWebhookJob.perform_now(@delivery)
    end
  end

  test "mark_failed settles the delivery after exhausted retries" do
    @delivery.mark_failed

    assert @delivery.failed?
  end
end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bin/rails test test/models/webhook_delivery_test.rb test/jobs/deliver_webhook_job_test.rb`
Expected: PASS

- [ ] **Step 7: Full suite + rubocop, then commit**

Run: `bin/rails test && bin/rubocop`

```bash
git add db/migrate db/schema.rb app/models/webhook_delivery.rb app/models/webhook_endpoint.rb app/jobs/deliver_webhook_job.rb test/models/webhook_delivery_test.rb test/jobs/deliver_webhook_job_test.rb test/test_helper.rb
git commit -m "feat: WebhookDelivery with signed HTTP delivery and retrying DeliverWebhookJob"
```

---

### Task 8: Outbound fan-out from `WebhookLog#process`

**Files:**
- Modify: `app/models/webhook_log.rb` (fill the `relay_to_endpoints` seam)
- Modify: `test/models/webhook_log_test.rb` (fan-out tests)

**Interfaces:**
- Consumes: `email.project.webhook_endpoints.active`, `WebhookEndpoint#subscribed_to?`, `endpoint.deliveries.create!`, `WebhookDelivery#deliver_later`, `Email::SesEvent` (`event_type`, `recipients`, `occurred_at`, `payload`).
- Produces: one `WebhookDelivery` (+ enqueued `DeliverWebhookJob`) per active, subscribed endpoint per ingested event. Delivery payload shape: `{ "event", "email_id" (public_id), "recipients", "occurred_at", "payload" (raw SES message) }`. Runs inside the ingestion transaction but only ENQUEUES — `enqueue_after_transaction_commit` defers the jobs to commit.

- [ ] **Step 1: Write the failing tests**

Add to `test/models/webhook_log_test.rb` (reuse the file's existing `matched_email` / `process_fixture` private helpers):

```ruby
  test "an ingested event fans out to active subscribed endpoints" do
    email = matched_email

    assert_difference -> { WebhookDelivery.count }, +1 do
      assert_enqueued_with(job: DeliverWebhookJob) do
        process_fixture("bounce_permanent")
      end
    end

    delivery = WebhookDelivery.last
    assert_equal webhook_endpoints(:acme_all), delivery.webhook_endpoint
    assert_equal email, delivery.email
    assert_equal "bounce", delivery.event_type
    assert_equal "bounce", delivery.payload["event"]
    assert_equal email.public_id, delivery.payload["email_id"]
    assert delivery.payload["payload"].present?, "carries the raw SES message"
  end

  test "fan-out skips inactive and unsubscribed endpoints" do
    matched_email

    # acme_inactive subscribes to bounce but is inactive; acme_all does not subscribe to send.
    assert_no_difference -> { WebhookDelivery.count } do
      process_fixture("send")
    end
  end

  test "fan-out never reaches endpoints of other projects" do
    matched_email
    process_fixture("bounce_permanent")

    assert_empty webhook_endpoints(:globex_bounces).deliveries
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/webhook_log_test.rb`
Expected: the three new tests FAIL (seam is a no-op)

- [ ] **Step 3: Fill the seam**

In `app/models/webhook_log.rb`, replace the `relay_to_endpoints` method (and its seam comment) with:

```ruby
    # Runs inside the ingestion transaction, so this only ENQUEUES — the
    # HTTP happens in DeliverWebhookJob after commit (enqueue_after_transaction_commit).
    def relay_to_endpoints(email, event)
      email.project.webhook_endpoints.active.each do |endpoint|
        if endpoint.subscribed_to?(event.event_type)
          endpoint.deliveries.create!(email: email, event_type: event.event_type,
            payload: delivery_payload(email, event)).deliver_later
        end
      end
    end

    def delivery_payload(email, event)
      { "event" => event.event_type, "email_id" => email.public_id,
        "recipients" => event.recipients, "occurred_at" => event.occurred_at,
        "payload" => event.payload }
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/models/webhook_log_test.rb`
Expected: PASS (all — including the pre-existing ingestion tests)

- [ ] **Step 5: Full suite + rubocop, then commit**

Run: `bin/rails test && bin/rubocop`

```bash
git add app/models/webhook_log.rb test/models/webhook_log_test.rb
git commit -m "feat: fan SES events out to subscribed webhook endpoints"
```

---

### Task 9: Webhook endpoints dashboard — CRUD, reveal-once, delivery log

**Files:**
- Create: `app/controllers/webhook_endpoints_controller.rb`
- Create: `app/views/webhook_endpoints/index.html.erb`, `show.html.erb`, `new.html.erb`, `edit.html.erb`, `_form.html.erb`, `create.html.erb`
- Modify: `config/routes.rb`, `app/views/layouts/_nav.html.erb`
- Create: `test/controllers/webhook_endpoints_controller_test.rb`

**Interfaces:**
- Consumes: `WebhookEndpoint` (Task 6), `WebhookEndpoint#success_rate`, `endpoint.deliveries.reverse_chronologically`, `authorize_capability! :manage_webhooks`.
- Produces: `resources :webhook_endpoints` routes. `create` renders a one-time secret reveal (`create.html.erb`); the secret is never displayed again. `show` is the delivery log with success rate.

- [ ] **Step 1: Write the failing controller tests**

Create `test/controllers/webhook_endpoints_controller_test.rb`:

```ruby
require "test_helper"

class WebhookEndpointsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
  end

  test "index lists only the current project's endpoints" do
    get webhook_endpoints_url

    assert_response :success
    assert_match "hooks.acme.com", response.body
    assert_no_match "hooks.globex.com", response.body
  end

  test "create reveals the secret exactly once" do
    assert_difference -> { projects(:acme_default).webhook_endpoints.count }, +1 do
      post webhook_endpoints_url, params: { webhook_endpoint: { url: "https://example.com/hook",
        events: [ "bounce", "complaint" ] } }
    end

    assert_response :success
    assert_match(/whsec_[A-Za-z0-9]{32}/, response.body)

    get webhook_endpoint_url(WebhookEndpoint.last)
    assert_no_match WebhookEndpoint.last.secret, response.body
  end

  test "create re-renders on validation errors" do
    post webhook_endpoints_url, params: { webhook_endpoint: { url: "http://insecure.example.com", events: [ "bounce" ] } }

    assert_response :unprocessable_entity
  end

  test "show renders the delivery log" do
    webhook_endpoints(:acme_all).deliveries.create!(event_type: "bounce", status: "succeeded",
      http_status: 200, latency_ms: 42, payload: {})
    webhook_endpoints(:acme_all).deliveries.create!(event_type: "bounce", status: "failed",
      http_status: 500, latency_ms: 61, payload: {})

    get webhook_endpoint_url(webhook_endpoints(:acme_all))

    assert_response :success
    assert_match "50.0", response.body
  end

  test "update toggles subscriptions and active state" do
    patch webhook_endpoint_url(webhook_endpoints(:acme_all)), params: { webhook_endpoint: {
      active: false, events: [ "bounce" ] } }

    assert_redirected_to webhook_endpoints_url
    assert_not webhook_endpoints(:acme_all).reload.active
  end

  test "destroy removes the endpoint" do
    assert_difference -> { WebhookEndpoint.count }, -1 do
      delete webhook_endpoint_url(webhook_endpoints(:acme_inactive))
    end
  end

  test "cross-tenant endpoints 404" do
    get webhook_endpoint_url(webhook_endpoints(:globex_bounces))
    assert_response :not_found
  end

  test "mutations require the manage_webhooks capability" do
    sign_in_as users(:sender)

    post webhook_endpoints_url, params: { webhook_endpoint: { url: "https://example.com/hook", events: [ "bounce" ] } }
    assert_response :forbidden

    delete webhook_endpoint_url(webhook_endpoints(:acme_all))
    assert_response :forbidden
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/webhook_endpoints_controller_test.rb`
Expected: FAIL (no route)

- [ ] **Step 3: Add routes and nav**

In `config/routes.rb`, after the sources block:

```ruby
  resources :webhook_endpoints
```

In `app/views/layouts/_nav.html.erb`, after Sources:

```erb
  <%= link_to "Webhooks", webhook_endpoints_path, class: "nav__link",
        aria: { current: current_page?(webhook_endpoints_path) ? "page" : nil } %>
```

- [ ] **Step 4: Implement the controller**

Create `app/controllers/webhook_endpoints_controller.rb`:

```ruby
class WebhookEndpointsController < ApplicationController
  include RequiresProject

  skip_before_action :require_project, only: :index
  before_action -> { authorize_capability! :manage_webhooks }, only: %i[ new create edit update destroy ]
  before_action :set_webhook_endpoint, only: %i[ show edit update destroy ]

  def index
    if Current.project
      @webhook_endpoints = Current.project.webhook_endpoints.order(:url)
    end
  end

  def show
    @deliveries = @webhook_endpoint.deliveries.reverse_chronologically.limit(50)
  end

  def new
    @webhook_endpoint = Current.project.webhook_endpoints.new
  end

  def create
    @webhook_endpoint = Current.project.webhook_endpoints.new(webhook_endpoint_params)

    if @webhook_endpoint.save
      render :create
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @webhook_endpoint.update(webhook_endpoint_params)
      redirect_to webhook_endpoints_path, notice: "Endpoint updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @webhook_endpoint.destroy
    redirect_to webhook_endpoints_path, notice: "Endpoint removed."
  end

  private
    def set_webhook_endpoint
      @webhook_endpoint = Current.project.webhook_endpoints.find(params[:id])
    end

    def webhook_endpoint_params
      params.require(:webhook_endpoint).permit(:url, :active, events: [])
    end
end
```

- [ ] **Step 5: Build the views**

Create `app/views/webhook_endpoints/_form.html.erb`:

```erb
<%= form_with model: webhook_endpoint do |form| %>
  <% if webhook_endpoint.errors.any? %>
    <div class="flash flash--alert"><%= webhook_endpoint.errors.full_messages.to_sentence %></div>
  <% end %>

  <div class="form-row">
    <%= form.label :url, "Endpoint URL" %>
    <%= form.url_field :url, class: "input", required: true, placeholder: "https://example.com/webhooks/departures" %>
  </div>

  <fieldset class="form-row">
    <legend>Events</legend>
    <%= form.collection_checkboxes :events, WebhookEndpoint::EVENT_TYPES.map { |type| [ type, type.humanize ] },
          :first, :last do |builder| %>
      <label class="checkbox">
        <%= builder.checkbox %>
        <%= builder.text %>
      </label>
    <% end %>
  </fieldset>

  <% if webhook_endpoint.persisted? %>
    <div class="form-row">
      <label class="checkbox">
        <%= form.checkbox :active %>
        Active
      </label>
    </div>
  <% end %>

  <%= form.submit webhook_endpoint.persisted? ? "Update endpoint" : "Add endpoint", class: "btn btn--primary btn--large" %>
<% end %>
```

Create `app/views/webhook_endpoints/new.html.erb`:

```erb
<% content_for :title, "New webhook endpoint" %>
<h1>New webhook endpoint</h1>
<%= render "form", webhook_endpoint: @webhook_endpoint %>
```

Create `app/views/webhook_endpoints/edit.html.erb`:

```erb
<% content_for :title, "Edit webhook endpoint" %>
<h1>Edit webhook endpoint</h1>
<%= render "form", webhook_endpoint: @webhook_endpoint %>
```

Create `app/views/webhook_endpoints/create.html.erb` (the one-time reveal):

```erb
<% content_for :title, "Webhook endpoint created" %>

<h1>Endpoint created</h1>

<div class="secret-reveal">
  <p>
    This signing secret is shown <strong>only once</strong>. Store it now — deliveries are signed with
    <code>Departures-Signature: t={timestamp},v1=HMAC-SHA256(secret, "{timestamp}.{body}")</code>.
  </p>
  <p>
    <code><%= @webhook_endpoint.secret %></code>
    <button type="button" class="btn btn--secondary btn--medium" data-controller="clipboard"
      data-clipboard-text-value="<%= @webhook_endpoint.secret %>" data-action="clipboard#copy">
      Copy secret
    </button>
  </p>
</div>

<p><%= link_to "Back to webhooks", webhook_endpoints_path, class: "btn btn--plain btn--medium" %></p>
```

Create `app/views/webhook_endpoints/index.html.erb`:

```erb
<% content_for :title, "Webhooks" %>

<% if Current.project %>
  <header class="page-header">
    <h1>Webhooks</h1>
    <% if Current.workspace.capability?(Current.user, :manage_webhooks) %>
      <%= link_to "New endpoint", new_webhook_endpoint_path, class: "btn btn--primary btn--medium" %>
    <% end %>
  </header>

  <% if @webhook_endpoints.any? %>
    <table class="settings-table">
      <thead>
        <tr><th>URL</th><th>Events</th><th>Status</th><th>Success rate</th><th></th></tr>
      </thead>
      <tbody>
        <% @webhook_endpoints.each do |endpoint| %>
          <tr>
            <td><%= link_to endpoint.url, webhook_endpoint_path(endpoint) %></td>
            <td><%= endpoint.events.join(", ") %></td>
            <td><%= endpoint.active? ? "active" : "paused" %></td>
            <td><%= endpoint.success_rate ? "#{endpoint.success_rate}%" : "—" %></td>
            <td>
              <% if Current.workspace.capability?(Current.user, :manage_webhooks) %>
                <%= link_to "Edit", edit_webhook_endpoint_path(endpoint), class: "btn btn--plain btn--medium" %>
              <% end %>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
  <% else %>
    <p>No webhook endpoints yet. Relay delivery events to your own systems.</p>
  <% end %>
<% else %>
  <p>No active project yet.</p>
<% end %>
```

Create `app/views/webhook_endpoints/show.html.erb`:

```erb
<% content_for :title, @webhook_endpoint.url %>

<header class="page-header">
  <h1><%= @webhook_endpoint.url %></h1>
  <span><%= @webhook_endpoint.success_rate ? "#{@webhook_endpoint.success_rate}% delivered" : "No deliveries yet" %></span>
</header>

<% if @deliveries.any? %>
  <table class="settings-table">
    <thead>
      <tr><th>Event</th><th>Status</th><th>HTTP</th><th>Latency</th><th>Attempts</th><th>When</th></tr>
    </thead>
    <tbody>
      <% @deliveries.each do |delivery| %>
        <tr>
          <td><%= delivery.event_type %></td>
          <td><%= delivery.status %></td>
          <td><%= delivery.http_status || "—" %></td>
          <td><%= delivery.latency_ms ? "#{delivery.latency_ms} ms" : "—" %></td>
          <td><%= delivery.attempts %></td>
          <td><%= delivery.created_at.to_fs(:short) %></td>
        </tr>
      <% end %>
    </tbody>
  </table>
<% else %>
  <p>No deliveries yet.</p>
<% end %>
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bin/rails test test/controllers/webhook_endpoints_controller_test.rb`
Expected: PASS

- [ ] **Step 7: Full suite + rubocop, verify light/dark, then commit**

Run: `bin/rails test && bin/rubocop`

```bash
git add config/routes.rb app/controllers/webhook_endpoints_controller.rb app/views/webhook_endpoints app/views/layouts/_nav.html.erb test/controllers/webhook_endpoints_controller_test.rb
git commit -m "feat: webhook endpoints dashboard with one-time secret reveal and delivery log"
```

---

### Task 10: `Template` model + `{{ var }}` renderer

**Files:**
- Create: `db/migrate/<timestamp>_create_templates.rb`
- Create: `app/models/template.rb`
- Create: `test/fixtures/templates.yml`
- Create: `test/models/template_test.rb`
- Modify: `app/models/project.rb`, `test/test_helper.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Template#render(variables = {}) → Template::Rendered` (a `Data` with `.subject`, `.html`, `.text`; `{{ var }}` substitution, HTML-escaped values in the html body only, missing variables become empty strings); slug unique per project; `project.templates`. Consumed by `EmailSubmission` in Task 12.

- [ ] **Step 1: Generate the migration**

Run: `bin/rails generate migration CreateTemplates`

```ruby
class CreateTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :templates do |t|
      t.references :project, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.string :name, null: false
      t.string :slug, null: false
      t.string :subject
      t.text :html_body
      t.text :text_body

      t.timestamps
    end

    add_index :templates, %i[ project_id slug ], unique: true
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write fixtures**

Create `test/fixtures/templates.yml`:

```yaml
acme_welcome:
  project: acme_default
  workspace: acme
  name: Welcome
  slug: welcome
  subject: "Welcome, {{ name }}!"
  html_body: "<h1>Hi {{ name }}</h1><p>Thanks for joining {{ company }}.</p>"
  text_body: "Hi {{ name }} — thanks for joining {{ company }}."

globex_receipt:
  project: globex_default
  workspace: globex
  name: Receipt
  slug: receipt
  subject: "Your receipt"
  text_body: "Total: {{ total }}"
```

- [ ] **Step 3: Write the failing tests**

Create `test/models/template_test.rb`:

```ruby
require "test_helper"

class TemplateTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "workspace defaults from the project and slug is unique per project" do
    template = projects(:acme_default).templates.create!(name: "Reset", slug: "reset", text_body: "Hi")
    assert_equal workspaces(:acme), template.workspace

    duplicate = projects(:acme_default).templates.build(name: "Reset 2", slug: "reset", text_body: "Hi")
    assert_not duplicate.valid?

    other_project = projects(:globex_default).templates.build(name: "Reset", slug: "reset", text_body: "Hi")
    assert other_project.valid?
  end

  test "slug is normalized and constrained" do
    template = projects(:acme_default).templates.create!(name: "X", slug: "  My-Slug ", text_body: "Hi")
    assert_equal "my-slug", template.slug

    assert_not projects(:acme_default).templates.build(name: "X", slug: "no spaces", text_body: "Hi").valid?
  end

  test "a body is required" do
    assert_not projects(:acme_default).templates.build(name: "X", slug: "x").valid?
    assert projects(:acme_default).templates.build(name: "X", slug: "x", html_body: "<p>Hi</p>").valid?
  end

  test "render substitutes variables across subject, html, and text" do
    rendered = templates(:acme_welcome).render({ "name" => "Ada", "company" => "Acme" })

    assert_equal "Welcome, Ada!", rendered.subject
    assert_equal "<h1>Hi Ada</h1><p>Thanks for joining Acme.</p>", rendered.html
    assert_equal "Hi Ada — thanks for joining Acme.", rendered.text
  end

  test "render escapes HTML in the html body only" do
    rendered = templates(:acme_welcome).render({ "name" => "<script>alert(1)</script>", "company" => "A&B" })

    assert_includes rendered.html, "&lt;script&gt;"
    assert_includes rendered.html, "A&amp;B"
    assert_includes rendered.text, "A&B"
    assert_includes rendered.subject, "<script>"
  end

  test "render blanks missing variables and tolerates whitespace in tags" do
    template = projects(:acme_default).templates.create!(name: "Spacey", slug: "spacey",
      text_body: "Hello {{  name  }}, welcome to {{ company }}")

    assert_equal "Hello Ada, welcome to ", template.render({ "name" => "Ada" }).text
  end
end
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `bin/rails test test/models/template_test.rb`
Expected: FAIL (uninitialized constant)

- [ ] **Step 5: Implement the model**

Create `app/models/template.rb`:

```ruby
class Template < ApplicationRecord
  VARIABLE_PATTERN = /\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/
  SLUG_FORMAT = /\A[a-z0-9]+(-[a-z0-9]+)*\z/

  Rendered = Data.define(:subject, :html, :text)

  belongs_to :project
  belongs_to :workspace, default: -> { project.workspace }

  normalizes :slug, with: ->(slug) { slug.strip.downcase }

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: { scope: :project_id },
    format: { with: SLUG_FORMAT, message: "may only contain lowercase letters, numbers, and dashes" }
  validate :validate_body_presence

  def render(variables = {})
    Rendered.new(subject: substitute(subject, variables, escape: false),
      html: substitute(html_body, variables, escape: true),
      text: substitute(text_body, variables, escape: false))
  end

  private
    def validate_body_presence
      if html_body.blank? && text_body.blank?
        errors.add(:base, "an html or text body is required")
      end
    end

    def substitute(content, variables, escape:)
      if content.blank?
        content
      else
        content.gsub(VARIABLE_PATTERN) do
          value = variables[Regexp.last_match(1)].to_s
          escape ? ERB::Util.html_escape(value) : value
        end
      end
    end
end
```

In `app/models/project.rb`, add:

```ruby
  has_many :templates, dependent: :destroy
```

In `test/test_helper.rb`, inside `wipe_workspace_records`, add before `Project.delete_all`:

```ruby
      Template.delete_all
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bin/rails test test/models/template_test.rb`
Expected: PASS

- [ ] **Step 7: Full suite + rubocop, then commit**

Run: `bin/rails test && bin/rubocop`

```bash
git add db/migrate db/schema.rb app/models/template.rb app/models/project.rb test/fixtures/templates.yml test/models/template_test.rb test/test_helper.rb
git commit -m "feat: Template model with escaped {{ var }} rendering"
```

---

### Task 11: Templates dashboard

**Files:**
- Create: `app/controllers/templates_controller.rb`
- Create: `app/views/templates/index.html.erb`, `new.html.erb`, `edit.html.erb`, `_form.html.erb`
- Modify: `config/routes.rb`, `app/views/layouts/_nav.html.erb`
- Create: `test/controllers/templates_controller_test.rb`

**Interfaces:**
- Consumes: `Template` (Task 10), `authorize_capability! :manage_templates`.
- Produces: `resources :templates` (no `show` — `edit` is the detail view).

- [ ] **Step 1: Write the failing controller tests**

Create `test/controllers/templates_controller_test.rb`:

```ruby
require "test_helper"

class TemplatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
  end

  test "index lists only the current project's templates" do
    get templates_url

    assert_response :success
    assert_match "welcome", response.body
    assert_no_match "receipt", response.body
  end

  test "create adds a template" do
    assert_difference -> { projects(:acme_default).templates.count }, +1 do
      post templates_url, params: { template: { name: "Reset password", slug: "reset-password",
        subject: "Reset your password", text_body: "Click: {{ url }}" } }
    end

    assert_redirected_to templates_url
  end

  test "create re-renders on validation errors" do
    post templates_url, params: { template: { name: "", slug: "bad slug!" } }

    assert_response :unprocessable_entity
  end

  test "update edits a template" do
    patch template_url(templates(:acme_welcome)), params: { template: { subject: "Hello {{ name }}" } }

    assert_redirected_to templates_url
    assert_equal "Hello {{ name }}", templates(:acme_welcome).reload.subject
  end

  test "destroy removes a template" do
    assert_difference -> { Template.count }, -1 do
      delete template_url(templates(:acme_welcome))
    end
  end

  test "cross-tenant templates 404" do
    patch template_url(templates(:globex_receipt)), params: { template: { name: "X" } }
    assert_response :not_found
  end

  test "mutations require the manage_templates capability" do
    sign_in_as users(:sender)

    post templates_url, params: { template: { name: "X", slug: "x", text_body: "x" } }
    assert_response :forbidden
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/templates_controller_test.rb`
Expected: FAIL (no route)

- [ ] **Step 3: Routes, nav, controller, views**

In `config/routes.rb`, after `resources :webhook_endpoints`:

```ruby
  resources :templates, except: :show
```

Nav link after Webhooks in `_nav.html.erb`:

```erb
  <%= link_to "Templates", templates_path, class: "nav__link",
        aria: { current: current_page?(templates_path) ? "page" : nil } %>
```

Create `app/controllers/templates_controller.rb`:

```ruby
class TemplatesController < ApplicationController
  include RequiresProject

  skip_before_action :require_project, only: :index
  before_action -> { authorize_capability! :manage_templates }, except: :index
  before_action :set_template, only: %i[ edit update destroy ]

  def index
    if Current.project
      @templates = Current.project.templates.order(:slug)
    end
  end

  def new
    @template = Current.project.templates.new
  end

  def create
    @template = Current.project.templates.new(template_params)

    if @template.save
      redirect_to templates_path, notice: "Template created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @template.update(template_params)
      redirect_to templates_path, notice: "Template updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @template.destroy
    redirect_to templates_path, notice: "Template deleted."
  end

  private
    def set_template
      @template = Current.project.templates.find(params[:id])
    end

    def template_params
      params.require(:template).permit(:name, :slug, :subject, :html_body, :text_body)
    end
end
```

Create `app/views/templates/_form.html.erb`:

```erb
<%= form_with model: template do |form| %>
  <% if template.errors.any? %>
    <div class="flash flash--alert"><%= template.errors.full_messages.to_sentence %></div>
  <% end %>

  <div class="form-row">
    <%= form.label :name %>
    <%= form.text_field :name, class: "input", required: true %>
  </div>
  <div class="form-row">
    <%= form.label :slug %>
    <%= form.text_field :slug, class: "input", required: true, placeholder: "welcome-email" %>
  </div>
  <div class="form-row">
    <%= form.label :subject %>
    <%= form.text_field :subject, class: "input", placeholder: "Welcome, {{ name }}!" %>
  </div>
  <div class="form-row">
    <%= form.label :html_body, "HTML body" %>
    <%= form.textarea :html_body, class: "input input--textarea", rows: 10 %>
  </div>
  <div class="form-row">
    <%= form.label :text_body, "Text body" %>
    <%= form.textarea :text_body, class: "input input--textarea", rows: 6 %>
  </div>

  <p>Use <code>{{ variable }}</code> placeholders; senders pass values via the API's <code>variables</code> object.</p>

  <%= form.submit template.persisted? ? "Update template" : "Create template", class: "btn btn--primary btn--large" %>
<% end %>
```

Create `app/views/templates/new.html.erb`:

```erb
<% content_for :title, "New template" %>
<h1>New template</h1>
<%= render "form", template: @template %>
```

Create `app/views/templates/edit.html.erb`:

```erb
<% content_for :title, "Edit template" %>
<h1>Edit template</h1>
<%= render "form", template: @template %>
```

Create `app/views/templates/index.html.erb`:

```erb
<% content_for :title, "Templates" %>

<% if Current.project %>
  <header class="page-header">
    <h1>Templates</h1>
    <% if Current.workspace.capability?(Current.user, :manage_templates) %>
      <%= link_to "New template", new_template_path, class: "btn btn--primary btn--medium" %>
    <% end %>
  </header>

  <% if @templates.any? %>
    <table class="settings-table">
      <thead>
        <tr><th>Name</th><th>Slug</th><th>Subject</th><th></th></tr>
      </thead>
      <tbody>
        <% @templates.each do |template| %>
          <tr>
            <td><%= template.name %></td>
            <td><code><%= template.slug %></code></td>
            <td><%= template.subject %></td>
            <td>
              <% if Current.workspace.capability?(Current.user, :manage_templates) %>
                <%= link_to "Edit", edit_template_path(template), class: "btn btn--plain btn--medium" %>
              <% end %>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
  <% else %>
    <p>No templates yet. Templates let API callers send by slug with <code>{{ var }}</code> substitution.</p>
  <% end %>
<% else %>
  <p>No active project yet.</p>
<% end %>
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/controllers/templates_controller_test.rb`
Expected: PASS

- [ ] **Step 5: Full suite + rubocop, then commit**

Run: `bin/rails test && bin/rubocop`

```bash
git add config/routes.rb app/controllers/templates_controller.rb app/views/templates app/views/layouts/_nav.html.erb test/controllers/templates_controller_test.rb
git commit -m "feat: templates dashboard"
```

---

### Task 12: `EmailSubmission` template resolution

**Files:**
- Modify: `app/models/email_submission.rb`
- Modify: `app/controllers/api/emails_controller.rb` (permit `variables`)
- Modify: `test/models/email_submission_test.rb`
- Modify: `test/controllers/api/emails_controller_test.rb`

**Interfaces:**
- Consumes: `Template#render(variables)` (Task 10), `project.templates`.
- Produces: `EmailSubmission` accepts `template_id` (slug or numeric id) + `variables` (string-keyed hash); resolves them into the created `Email`'s subject/html_body/text_body. Unknown template → 422 `"template_id does not match any template"`. The Phase-1 `validate_template_supported` rejection is removed. Subject XOR template rule unchanged.

- [ ] **Step 1: Write the failing tests**

Add to `test/models/email_submission_test.rb`:

```ruby
  test "template: resolves by slug and renders subject and bodies into the email" do
    submission = EmailSubmission.new(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", to: [ "user@example.com" ],
      template_id: "welcome", variables: { "name" => "Ada", "company" => "Acme" })

    email = submission.save
    assert email
    assert_equal "Welcome, Ada!", email.subject
    assert_includes email.html_body, "<h1>Hi Ada</h1>"
    assert_includes email.text_body, "thanks for joining Acme"
  end

  test "template: resolves by numeric id" do
    submission = EmailSubmission.new(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", to: [ "user@example.com" ],
      template_id: templates(:acme_welcome).id.to_s, variables: { "name" => "Ada" })

    assert submission.valid?
  end

  test "template: unknown template is rejected" do
    submission = EmailSubmission.new(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", to: [ "user@example.com" ], template_id: "nope")

    assert_not submission.valid?
    assert submission.errors[:template_id].any?
  end

  test "template: another project's template is not visible" do
    submission = EmailSubmission.new(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", to: [ "user@example.com" ], template_id: "receipt")

    assert_not submission.valid?
  end

  test "template: subject and template together are still rejected" do
    submission = EmailSubmission.new(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", to: [ "user@example.com" ], subject: "Hi", template_id: "welcome")

    assert_not submission.valid?
  end
```

Remove/replace the Phase-1 test asserting `template_id` is rejected as unsupported (search the file for `"templates are not yet supported"`).

Add to `test/controllers/api/emails_controller_test.rb` (follow the file's existing auth-header helper conventions for POSTing as an API key with the `send` scope):

```ruby
  test "sends with a template and variables" do
    post api_emails_url,
      params: { from: "hello@acme.com", to: [ "user@example.com" ],
                template_id: "welcome", variables: { name: "Ada", company: "Acme" } },
      headers: send_auth_headers, as: :json

    assert_response :accepted
    assert_equal "Welcome, Ada!", Email.order(:id).last.subject
  end
```

(If the file's helper for authenticated headers has a different name, use that; the assertion body stays the same.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/email_submission_test.rb test/controllers/api/emails_controller_test.rb`
Expected: new tests FAIL ("templates are not yet supported")

- [ ] **Step 3: Implement resolution in `EmailSubmission`**

In `app/models/email_submission.rb`:

1. Add `variables` to the reader list and initialize it:

```ruby
  attr_accessor :project, :source, :api_key, :from, :subject, :template_id, :html, :text
  attr_reader :to, :cc, :bcc, :headers, :tags, :attachments, :variables
```

```ruby
  def initialize(attributes = {})
    @to, @cc, @bcc = [], [], []
    @headers, @tags = {}, {}
    @attachments = []
    @variables = {}
    super
  end
```

```ruby
  def variables=(value)
    @variables = (value || {}).to_h.transform_keys(&:to_s)
  end
```

2. In the `validate` list, replace `:validate_template_supported` with `:validate_template`.

3. Replace the `validate_template_supported` method (and its comment) with:

```ruby
    def validate_template
      if template_id.present? && template.nil?
        errors.add(:template_id, "does not match any template")
      end
    end
```

4. In `create_email`, switch the three content fields to their effective versions:

```ruby
        email = Email.create!(project: project, source: source, api_key: api_key,
          from: from, subject: effective_subject, html_body: effective_html, text_body: effective_text,
          headers: headers, tags: tags)
```

5. Add the private resolution methods (place them after `validate_guardrails`'s helpers, before `all_recipients`, keeping invocation order):

```ruby
    def template
      if project && template_id.present?
        @template ||= project.templates.find_by(slug: template_id.to_s.downcase) ||
          project.templates.find_by(id: template_id)
      end
    end

    def rendered_template
      @rendered_template ||= template&.render(variables)
    end

    def effective_subject
      template ? rendered_template.subject : subject
    end

    def effective_html
      template ? rendered_template.html : html
    end

    def effective_text
      template ? rendered_template.text : text
    end
```

Note `validate_body_presence` already passes when `template_id` is present (the template's own body-presence validation guarantees content).

- [ ] **Step 4: Permit the API params**

In `app/controllers/api/emails_controller.rb`, extend `submission_attributes`' permit list:

```ruby
      params.permit(:from, :subject, :html, :text, :template_id,
        to: [], cc: [], bcc: [], headers: {}, tags: {}, variables: {},
        attachments: [ %i[ filename content_type content ] ])
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/models/email_submission_test.rb test/controllers/api/emails_controller_test.rb`
Expected: PASS

- [ ] **Step 6: Full suite + rubocop, then commit**

Run: `bin/rails test && bin/rubocop`

```bash
git add app/models/email_submission.rb app/controllers/api/emails_controller.rb test/models/email_submission_test.rb test/controllers/api/emails_controller_test.rb
git commit -m "feat: EmailSubmission resolves template_id and variables through Template#render"
```

---

### Task 13: API keys dashboard — issue, reveal-once, rotate, revoke

**Files:**
- Create: `app/controllers/api_keys_controller.rb`
- Create: `app/controllers/api_keys/rotations_controller.rb`
- Create: `app/views/api_keys/index.html.erb`, `new.html.erb`, `create.html.erb`
- Modify: `config/routes.rb`, `app/views/layouts/_nav.html.erb`
- Create: `test/controllers/api_keys_controller_test.rb`

**Interfaces:**
- Consumes: `ApiKey.issue(project:, name:, scopes:, expires_in:)`, `ApiKey#token` (plaintext, only on the issuing instance), `ApiKey#revoke`, `ApiKey#rotate → ApiKey` (new key with `#token`), `ApiKey#active?`, `authorize_capability! :manage_api_keys`.
- Produces: routes `api_keys_path`, `new_api_key_path`, `api_key_path` (DELETE = revoke), `api_key_rotation_path` (`POST /api_keys/:api_key_id/rotation`). `create` and rotation both render the one-time token reveal (`api_keys/create.html.erb`).

- [ ] **Step 1: Write the failing controller tests**

Create `test/controllers/api_keys_controller_test.rb`:

```ruby
require "test_helper"

class ApiKeysControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
    @api_key = ApiKey.issue(project: projects(:acme_default), name: "CI", scopes: %w[ send ])
  end

  test "index lists the project's keys by prefix, never the token" do
    get api_keys_url

    assert_response :success
    assert_match @api_key.prefix, response.body
    assert_no_match @api_key.token, response.body
  end

  test "create issues a key and reveals the token exactly once" do
    assert_difference -> { projects(:acme_default).api_keys.count }, +1 do
      post api_keys_url, params: { api_key: { name: "Production app", scopes: [ "send", "read:activity" ],
        expires_in: "90" } }
    end

    assert_response :success
    assert_match(/dp_[A-Za-z0-9]{48}/, response.body)

    key = ApiKey.order(:id).last
    assert_equal %w[ send read:activity ], key.scopes
    assert key.expires_at.between?(89.days.from_now, 91.days.from_now)

    get api_keys_url
    assert_no_match(/dp_[A-Za-z0-9]{48}/, response.body)
  end

  test "create without expiry issues a non-expiring key" do
    post api_keys_url, params: { api_key: { name: "Forever", scopes: [ "send" ], expires_in: "" } }

    assert_response :success
    assert_nil ApiKey.order(:id).last.expires_at
  end

  test "destroy revokes without deleting" do
    assert_no_difference -> { ApiKey.count } do
      delete api_key_url(@api_key)
    end

    assert_redirected_to api_keys_url
    assert @api_key.reload.revoked?
  end

  test "rotation revokes the old key and reveals a new one" do
    assert_difference -> { projects(:acme_default).api_keys.count }, +1 do
      post api_key_rotation_url(@api_key)
    end

    assert_response :success
    assert_match(/dp_[A-Za-z0-9]{48}/, response.body)
    assert @api_key.reload.revoked?
  end

  test "cross-tenant keys 404" do
    foreign = ApiKey.issue(project: projects(:globex_default), scopes: %w[ send ])

    delete api_key_url(foreign)
    assert_response :not_found

    post api_key_rotation_url(foreign)
    assert_response :not_found
  end

  test "mutations require the manage_api_keys capability" do
    sign_in_as users(:sender)

    post api_keys_url, params: { api_key: { name: "X", scopes: [ "send" ] } }
    assert_response :forbidden

    delete api_key_url(@api_key)
    assert_response :forbidden
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/api_keys_controller_test.rb`
Expected: FAIL (no route)

- [ ] **Step 3: Routes, nav, controllers**

In `config/routes.rb`, after `resources :templates`:

```ruby
  resources :api_keys, only: %i[ index new create destroy ] do
    scope module: :api_keys do
      resource :rotation, only: :create
    end
  end
```

Nav link after Templates:

```erb
  <%= link_to "API keys", api_keys_path, class: "nav__link",
        aria: { current: current_page?(api_keys_path) ? "page" : nil } %>
```

Create `app/controllers/api_keys_controller.rb`:

```ruby
class ApiKeysController < ApplicationController
  include RequiresProject

  skip_before_action :require_project, only: :index
  before_action -> { authorize_capability! :manage_api_keys }, except: :index

  def index
    if Current.project
      @api_keys = Current.project.api_keys.order(created_at: :desc)
    end
  end

  def new
    @api_key = Current.project.api_keys.new
  end

  def create
    @api_key = ApiKey.issue(project: Current.project, name: api_key_params[:name],
      scopes: Array(api_key_params[:scopes]).reject(&:blank?), expires_in: expires_in)
    render :create
  end

  def destroy
    Current.project.api_keys.find(params[:id]).revoke
    redirect_to api_keys_path, notice: "API key revoked."
  end

  private
    def api_key_params
      params.require(:api_key).permit(:name, :expires_in, scopes: [])
    end

    def expires_in
      api_key_params[:expires_in].presence&.to_i&.days
    end
end
```

Create `app/controllers/api_keys/rotations_controller.rb`:

```ruby
class ApiKeys::RotationsController < ApplicationController
  include RequiresProject

  before_action -> { authorize_capability! :manage_api_keys }

  def create
    @api_key = Current.project.api_keys.find(params[:api_key_id]).rotate
    render "api_keys/create"
  end
end
```

- [ ] **Step 4: Build the views**

Create `app/views/api_keys/new.html.erb`:

```erb
<% content_for :title, "New API key" %>

<h1>New API key</h1>

<%= form_with model: @api_key do |form| %>
  <div class="form-row">
    <%= form.label :name %>
    <%= form.text_field :name, class: "input", placeholder: "Production app" %>
  </div>

  <fieldset class="form-row">
    <legend>Scopes</legend>
    <label class="checkbox">
      <%= form.checkbox :scopes, { multiple: true, checked: true }, "send", nil %>
      send — POST /api/emails
    </label>
    <label class="checkbox">
      <%= form.checkbox :scopes, { multiple: true }, "read:activity", nil %>
      read:activity — GET /api/emails
    </label>
  </fieldset>

  <div class="form-row">
    <%= form.label :expires_in, "Expires" %>
    <%= form.select :expires_in, [ [ "Never", "" ], [ "30 days", "30" ], [ "90 days", "90" ], [ "1 year", "365" ] ],
          {}, class: "input input--select" %>
  </div>

  <%= form.submit "Create API key", class: "btn btn--primary btn--large" %>
<% end %>
```

Create `app/views/api_keys/create.html.erb` (the one-time reveal; also rendered by rotations):

```erb
<% content_for :title, "API key created" %>

<h1>API key created</h1>

<div class="secret-reveal">
  <p>This key is shown <strong>only once</strong>. Store it now.</p>
  <p>
    <code><%= @api_key.token %></code>
    <button type="button" class="btn btn--secondary btn--medium" data-controller="clipboard"
      data-clipboard-text-value="<%= @api_key.token %>" data-action="clipboard#copy">
      Copy key
    </button>
  </p>
  <p>Send it as <code>Authorization: Bearer <%= @api_key.prefix %>…</code></p>
</div>

<p><%= link_to "Back to API keys", api_keys_path, class: "btn btn--plain btn--medium" %></p>
```

Create `app/views/api_keys/index.html.erb`:

```erb
<% content_for :title, "API keys" %>

<% if Current.project %>
  <header class="page-header">
    <h1>API keys</h1>
    <% if Current.workspace.capability?(Current.user, :manage_api_keys) %>
      <%= link_to "New API key", new_api_key_path, class: "btn btn--primary btn--medium" %>
    <% end %>
  </header>

  <% if @api_keys.any? %>
    <table class="settings-table">
      <thead>
        <tr><th>Name</th><th>Prefix</th><th>Scopes</th><th>Last used</th><th>Status</th><th></th></tr>
      </thead>
      <tbody>
        <% @api_keys.each do |api_key| %>
          <tr>
            <td><%= api_key.name %></td>
            <td><code><%= api_key.prefix %>…</code></td>
            <td><%= api_key.scopes.join(", ") %></td>
            <td><%= api_key.last_used_at ? "#{time_ago_in_words(api_key.last_used_at)} ago" : "never" %></td>
            <td><%= api_key.active? ? "active" : (api_key.revoked? ? "revoked" : "expired") %></td>
            <td>
              <% if Current.workspace.capability?(Current.user, :manage_api_keys) && api_key.active? %>
                <%= button_to "Rotate", api_key_rotation_path(api_key), class: "btn btn--secondary btn--medium",
                      data: { turbo_confirm: "Rotate this key? The current key stops working immediately." } %>
                <%= button_to "Revoke", api_key_path(api_key), method: :delete, class: "btn btn--destroy btn--medium",
                      data: { turbo_confirm: "Revoke this key? Apps using it will stop sending." } %>
              <% end %>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
  <% else %>
    <p>No API keys yet. Issue one to start sending through <code>POST /api/emails</code>.</p>
  <% end %>
<% else %>
  <p>No active project yet.</p>
<% end %>
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/controllers/api_keys_controller_test.rb`
Expected: PASS

- [ ] **Step 6: Full suite + rubocop, verify light/dark, then commit**

Run: `bin/rails test && bin/rubocop`

```bash
git add config/routes.rb app/controllers/api_keys_controller.rb app/controllers/api_keys app/views/api_keys app/views/layouts/_nav.html.erb test/controllers/api_keys_controller_test.rb
git commit -m "feat: API keys dashboard with one-time reveal, rotation, and revocation"
```

---

### Task 14: Onboarding wizard + first-run gate

**Files:**
- Create: `app/models/workspace/onboardable.rb`
- Create: `app/models/workspace/onboarding.rb`
- Modify: `app/models/workspace.rb`
- Modify: `app/controllers/concerns/sets_current_workspace_and_project.rb` (gate + `allow_unonboarded_access`)
- Create: `app/controllers/onboardings_controller.rb`, `app/controllers/onboardings/completions_controller.rb`
- Create: `app/views/onboardings/show.html.erb`
- Modify: `config/routes.rb`, `test/fixtures/workspaces.yml`
- Modify: controllers that participate in onboarding (opt-out macro): `sources_controller.rb`, `sources/quota_syncs_controller.rb`, `domains_controller.rb`, `domains/checks_controller.rb`, `api_keys_controller.rb`, `api_keys/rotations_controller.rb`, `test_emails_controller.rb`, `emails_controller.rb`, `sessions_controller.rb`, `registrations_controller.rb`, `passwords_controller.rb`, `workspaces_controller.rb`, `workspaces/switches_controller.rb`, `workspaces/invitations_controller.rb`, `invitations/acceptances_controller.rb`
- Create: `test/models/workspace/onboarding_test.rb`, `test/controllers/onboardings_controller_test.rb`

**Interfaces:**
- Consumes: `workspace.setup_started_at` / `onboarded_at` columns (exist since Phase 0), step resources built in Tasks 2/5/13 + `test_emails` (Phase 4), `Domain#verified?`.
- Produces: `Workspace#onboarded?` / `#needs_onboarding?` / `#start_setup` / `#mark_onboarded` / `#onboarding_for(project) → Workspace::Onboarding`; presenter booleans `source_added?` / `domain_verified?` / `api_key_issued?` / `test_email_sent?` / `complete?`; routes `onboarding_path` (`GET /onboarding`), `onboarding_completion_path` (`POST /onboarding/completion`); a `require_onboarding` before_action in `SetsCurrentWorkspaceAndProject` redirecting un-onboarded workspaces to `/onboarding`, with class macro `allow_unonboarded_access` to opt controllers out.

- [ ] **Step 1: Stamp existing fixtures as onboarded**

In `test/fixtures/workspaces.yml`, add to BOTH `acme` and `globex`:

```yaml
  setup_started_at: <%= 3.weeks.ago %>
  onboarded_at: <%= 2.weeks.ago %>
```

- [ ] **Step 2: Write the failing model tests**

Create `test/models/workspace/onboarding_test.rb`:

```ruby
require "test_helper"

class Workspace::OnboardingTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    @workspace = workspaces(:acme)
    @project = projects(:acme_default)
  end

  test "onboarded? and needs_onboarding? read the timestamp" do
    assert @workspace.onboarded?
    assert_not @workspace.needs_onboarding?

    @workspace.update!(onboarded_at: nil)
    assert @workspace.needs_onboarding?
  end

  test "start_setup stamps once and never re-stamps" do
    @workspace.update!(setup_started_at: nil)

    @workspace.start_setup
    first_stamp = @workspace.reload.setup_started_at
    assert first_stamp.present?

    travel 1.hour do
      @workspace.start_setup
      assert_equal first_stamp, @workspace.reload.setup_started_at
    end
  end

  test "mark_onboarded stamps the workspace" do
    @workspace.update!(onboarded_at: nil)

    @workspace.mark_onboarded

    assert @workspace.reload.onboarded?
  end

  test "the checklist reflects the project's real state" do
    onboarding = @workspace.onboarding_for(@project)

    assert onboarding.source_added?
    assert onboarding.domain_verified?
    assert onboarding.test_email_sent?
    # acme has no ApiKey fixture; issue one to complete the list.
    assert_not onboarding.api_key_issued?
    assert_not onboarding.complete?

    ApiKey.issue(project: @project, scopes: %w[ send ])
    assert @workspace.onboarding_for(@project).complete?
  end

  test "the checklist is all false without a project" do
    onboarding = @workspace.onboarding_for(nil)

    assert_not onboarding.source_added?
    assert_not onboarding.complete?
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/models/workspace/onboarding_test.rb`
Expected: FAIL (undefined methods)

- [ ] **Step 4: Implement the concern and presenter**

Create `app/models/workspace/onboardable.rb`:

```ruby
module Workspace::Onboardable
  extend ActiveSupport::Concern

  def onboarded?
    onboarded_at.present?
  end

  def needs_onboarding?
    !onboarded?
  end

  def start_setup
    if setup_started_at.nil?
      update!(setup_started_at: Time.current)
    end
  end

  def mark_onboarded
    if needs_onboarding?
      update!(onboarded_at: Time.current)
    end
  end

  def onboarding_for(project)
    Workspace::Onboarding.new(self, project)
  end
end
```

Create `app/models/workspace/onboarding.rb` (presenter — plain Ruby class in the models layer):

```ruby
class Workspace::Onboarding
  attr_reader :workspace, :project

  def initialize(workspace, project)
    @workspace = workspace
    @project = project
  end

  def source_added?
    project.present? && project.sources.any?
  end

  def domain_verified?
    project.present? && project.domains.verified.any?
  end

  def api_key_issued?
    project.present? && project.api_keys.any?
  end

  def test_email_sent?
    project.present? && project.emails.any?
  end

  def complete?
    source_added? && domain_verified? && api_key_issued? && test_email_sent?
  end
end
```

In `app/models/workspace.rb`, add alongside the existing `include Roles`:

```ruby
  include Onboardable
```

- [ ] **Step 5: Run model tests to verify they pass**

Run: `bin/rails test test/models/workspace/onboarding_test.rb`
Expected: PASS

- [ ] **Step 6: Write the failing controller tests**

Create `test/controllers/onboardings_controller_test.rb`:

```ruby
require "test_helper"

class OnboardingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
  end

  test "an un-onboarded workspace is redirected to onboarding from gated pages" do
    workspaces(:acme).update!(onboarded_at: nil)

    get root_url
    assert_redirected_to onboarding_url

    get activity_url
    assert_redirected_to onboarding_url
  end

  test "onboarding-flow pages stay reachable while un-onboarded" do
    workspaces(:acme).update!(onboarded_at: nil)

    get onboarding_url
    assert_response :success

    get sources_url
    assert_response :success

    get domains_url
    assert_response :success

    get api_keys_url
    assert_response :success

    get new_test_email_url
    assert_response :success

    delete session_url
    assert_response :redirect
  end

  test "showing onboarding stamps setup_started_at" do
    workspaces(:acme).update!(onboarded_at: nil, setup_started_at: nil)

    get onboarding_url

    assert workspaces(:acme).reload.setup_started_at.present?
  end

  test "the checklist reflects step completion" do
    workspaces(:acme).update!(onboarded_at: nil)

    get onboarding_url

    assert_response :success
    assert_match "Add a source", response.body
    assert_match "Verify a domain", response.body
    assert_match "Issue an API key", response.body
    assert_match "Send a test email", response.body
  end

  test "completion marks the workspace onboarded and unlocks the dashboard" do
    workspaces(:acme).update!(onboarded_at: nil)

    post onboarding_completion_url
    assert_redirected_to root_url
    assert workspaces(:acme).reload.onboarded?

    get root_url
    assert_response :success
  end

  test "an onboarded workspace is never gated" do
    get root_url
    assert_response :success
  end
end
```

- [ ] **Step 7: Run tests to verify they fail**

Run: `bin/rails test test/controllers/onboardings_controller_test.rb`
Expected: FAIL (no route)

- [ ] **Step 8: Routes, gate, controllers, view**

In `config/routes.rb`, after the api_keys block:

```ruby
  resource :onboarding, only: :show do
    scope module: :onboardings do
      resource :completion, only: :create
    end
  end
```

Replace `app/controllers/concerns/sets_current_workspace_and_project.rb` with:

```ruby
module SetsCurrentWorkspaceAndProject
  extend ActiveSupport::Concern

  included do
    before_action :set_current_workspace, :set_current_project, :require_onboarding
  end

  class_methods do
    def allow_unonboarded_access(**options)
      skip_before_action :require_onboarding, **options
    end
  end

  private
    def set_current_workspace
      if authenticated?
        Current.workspace = Current.user.workspaces.find_by(id: session[:workspace_id]) ||
          Current.user.workspaces.order(:id).first
      end
    end

    def set_current_project
      if Current.workspace
        Current.project = Current.workspace.projects.active.find_by(slug: session[:project_slug]) ||
          Current.workspace.projects.active.order(:id).first
      end
    end

    def require_onboarding
      if Current.workspace&.needs_onboarding?
        redirect_to onboarding_path
      end
    end
end
```

Create `app/controllers/onboardings_controller.rb`:

```ruby
class OnboardingsController < ApplicationController
  allow_unonboarded_access

  def show
    Current.workspace.start_setup
    @onboarding = Current.workspace.onboarding_for(Current.project)
  end
end
```

Create `app/controllers/onboardings/completions_controller.rb`:

```ruby
class Onboardings::CompletionsController < ApplicationController
  allow_unonboarded_access

  def create
    Current.workspace.mark_onboarded
    redirect_to root_path, notice: "Welcome to Departures!"
  end
end
```

Add `allow_unonboarded_access` as the first line inside the class body of each controller listed in **Files** above (sources, sources/quota_syncs, domains, domains/checks, api_keys, api_keys/rotations, test_emails, emails, sessions, registrations, passwords, workspaces, workspaces/switches, workspaces/invitations, invitations/acceptances). For controllers that `include RequiresProject`, place the macro after the include. Do NOT add it to dashboards, activity, bounces, suppressions, exports, templates, or webhook_endpoints — those stay gated.

Create `app/views/onboardings/show.html.erb`:

```erb
<% content_for :title, "Get started" %>

<h1>Get started with Departures</h1>
<p>Four steps and your first email is on its way.</p>

<ol class="onboarding-steps">
  <li class="onboarding-step <%= "onboarding-step--done" if @onboarding.source_added? %>">
    <%= icon_tag @onboarding.source_added? ? "check" : "add" %>
    <div>
      <h2><%= link_to "Add a source", @onboarding.source_added? ? sources_path : new_source_path %></h2>
      <p>Connect the SES credentials and region Departures sends with.</p>
    </div>
  </li>

  <li class="onboarding-step <%= "onboarding-step--done" if @onboarding.domain_verified? %>">
    <%= icon_tag @onboarding.domain_verified? ? "check" : "add" %>
    <div>
      <h2><%= link_to "Verify a domain", domains_path %></h2>
      <p>Add your sending domain and create its DKIM records. Sends from unverified domains are rejected.</p>
    </div>
  </li>

  <li class="onboarding-step <%= "onboarding-step--done" if @onboarding.api_key_issued? %>">
    <%= icon_tag @onboarding.api_key_issued? ? "check" : "add" %>
    <div>
      <h2><%= link_to "Issue an API key", @onboarding.api_key_issued? ? api_keys_path : new_api_key_path %></h2>
      <p>Your apps authenticate to <code>POST /api/emails</code> with it.</p>
    </div>
  </li>

  <li class="onboarding-step <%= "onboarding-step--done" if @onboarding.test_email_sent? %>">
    <%= icon_tag @onboarding.test_email_sent? ? "check" : "add" %>
    <div>
      <h2><%= link_to "Send a test email", new_test_email_path %></h2>
      <p>Prove the pipeline end to end.</p>
    </div>
  </li>
</ol>

<%= button_to "Finish setup", onboarding_completion_path,
      class: "btn btn--primary btn--large",
      disabled: !@onboarding.complete? %>
<% unless @onboarding.complete? %>
  <p>You can finish setup once every step is done.</p>
<% end %>
```

Add to `app/assets/stylesheets/settings.css` inside `@layer modules`:

```css
  .onboarding-steps {
    display: grid;
    gap: var(--block-space);
    list-style: none;
    margin-block: var(--block-space);
    padding-inline-start: 0;
  }

  .onboarding-step {
    align-items: start;
    background-color: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 0.75em;
    display: flex;
    gap: var(--inline-space);
    padding: var(--block-space) var(--inline-space);
  }

  .onboarding-step--done {
    opacity: 0.7;
  }

  .onboarding-step h2 {
    font-size: var(--text-medium);
    margin-block: 0;
  }
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `bin/rails test test/controllers/onboardings_controller_test.rb`
Expected: PASS

- [ ] **Step 10: Full suite — expect gate fallout, fix it**

Run: `bin/rails test`

The gate touches every dashboard controller. With the fixture stamps from Step 1 the suite should stay green; if any test creates a fresh workspace mid-test (e.g. registration or invitation flows) and then hits a gated page, either follow the redirect to `/onboarding` in the assertion or stamp `onboarded_at` in the test — pick whichever matches what the test is actually about.

- [ ] **Step 11: Rubocop, verify light/dark, then commit**

Run: `bin/rubocop`

```bash
git add config/routes.rb app/models/workspace.rb app/models/workspace app/controllers app/views/onboardings app/assets/stylesheets/settings.css test/fixtures/workspaces.yml test/models/workspace test/controllers/onboardings_controller_test.rb
git commit -m "feat: onboarding wizard with first-run gate keyed off workspace onboarding state"
```

---

### Task 15: Phase wrap-up

**Files:**
- Modify: `docs/plans/departures-execution-plan.md` (Phase 5 status line)

- [ ] **Step 1: Run full CI**

Run: `bin/ci`
Expected: setup, rubocop, bundler-audit, importmap audit, brakeman, tests, seed replant — all green. Brakeman may flag the outbound webhook HTTP call (`Net::HTTP` with a model-supplied URL); that URL is operator-configured and https-validated — if flagged, add a Brakeman ignore entry with that justification rather than weakening the model validation.

- [ ] **Step 2: Update the master plan**

In `docs/plans/departures-execution-plan.md`, under the `### Phase 5` heading, add:

```markdown
Detailed plan: **docs/plans/phase-5-platform-plan.md** (complete).
```

- [ ] **Step 3: Request code review**

Per the execution protocol, run `superpowers:requesting-code-review` against `docs/patterns-and-best-practices.md`, `docs/style-guide.md`, and this phase's roadmap bullets (larasend evaluation §Phase 5). Address findings, keep the suite green.

- [ ] **Step 4: Commit**

```bash
git add docs/plans/departures-execution-plan.md
git commit -m "docs: phase 5 plan status"
```

---

## Self-review notes (spec coverage)

- 5.1 domains: Tasks 1–2 (provision/check/DKIM CNAMEs/re-check/`manage_domains`). ✔
- 5.2 guardrails: Tasks 3–4 (`sync_quota` via `get_account`, 6 h staleness, ≥100 sends/30 d AND ≥0.1 % breaker, from-domain-verified flip, seams wired). ✔
- 5.3 outbound webhooks: Tasks 6–9 (encrypted `whsec_`, events json, active flag; HMAC `Departures-Signature: t={ts},v1={sig}`; per-attempt log with status/latency/body; `:webhooks` queue, 3 tries; fan-out fills the Phase 3 seam, enqueue-only inside the transaction; one-time reveal; delivery log + success rate). ✔
- 5.4 templates: Tasks 10–12 (`{{ var }}` gsub with HTML escaping, no Liquid; slug unique per project; `manage_templates`; `EmailSubmission` resolves `template_id`). ✔
- 5.5 onboarding: Task 14 (workspace → source → domain → API key → test send; keyed off `setup_started_at`/`onboarded_at`; first-run gate in `SetsCurrentWorkspaceAndProject`). ✔
- Section A extras honored: `ApiKeys::RotationsController#create`, `Sources::QuotaSyncsController#create`, `Domains::ChecksController#create` verb→resource mappings; no bang methods; jobs 3–6 lines; presenters in `app/models/`; scoping through `Current.*` with cross-tenant 404s.

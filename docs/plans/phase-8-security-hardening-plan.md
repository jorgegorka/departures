# Phase 8 — Security Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TOTP two-factor authentication with recovery codes, per-workspace 2FA enforcement, session management (list/revoke), a curated workspace audit log with viewer and retention pruning, closed out by an adversarial security review.

**Architecture:** Pure-Ruby RFC 6238 TOTP in `lib/totp.rb` (autoloaded); user-facing 2FA behavior in a `User::TwoFactor` concern with an AR-encrypted secret; login becomes a two-step flow (password → signed pending cookie → challenge) without ever creating a session early; enforcement is one before_action in `SetsCurrentWorkspaceAndProject`; audit events are explicit `AuditEvent.record` calls at curated call sites — no callbacks; QR enrollment renders client-side from a vendored `qrcode-generator` package pinned via importmap.

**Tech Stack:** Rails 8.1, SQLite, Hotwire, Minitest + fixtures, OpenSSL (stdlib), importmap-vendored `qrcode-generator` (MIT, no gem, no build).

**Spec:** `docs/superpowers/specs/2026-07-11-phase-8-security-hardening-design.md`.

## Global Constraints

- Default integer primary keys. **No new gems.** The only new dependency is the `qrcode-generator` npm package vendored into `vendor/javascript` by `bin/importmap pin` (self-contained ESM file, no external requests at runtime).
- Bang methods only when a non-bang counterpart exists — every method in this phase is bang-less.
- Expanded conditionals over guard clauses (guards OK only at the start of a non-trivial body); private methods indented under `private`, no blank line after the modifier; method order: class methods → public (`initialize` first) → private in invocation order (patterns §5.1).
- Thin controllers: ivars + one model call + respond. No business logic or query-building in controllers; UI filtering via case-scopes (patterns §2.4, §4.1).
- Dashboard scoping ALWAYS through `Current.user.workspaces` / `Current.workspace...` / `Current.user.sessions` — cross-tenant access must 404, never 403.
- `Current.session = sessions(:name)` in model-test setups that touch lambda association defaults (gotcha §7.3.1).
- Views use the existing token/component CSS (`.btn btn--primary|--secondary|--plain|--destroy btn--medium`, `.input`, utility classes seen in `app/views/api_keys/*`); verify light + dark render. No raw color values.
- `bin/rails test` and `bin/rubocop` green at the end of every task; each task ends with a commit.

**Standards to re-read per task type (master plan §C.3):** model tasks → patterns Part 2 + §5.1; controller tasks → Part 4.1–4.3; view tasks → `docs/style-guide.md` (tokens, buttons, inputs, dark mode).

**Facts about the current codebase this plan relies on** (verified 2026-07-11):

- `lib/` is autoloaded (`config.autoload_lib(ignore: %w[assets tasks])`) — `lib/totp.rb` defines `Totp` with no require.
- `users` has only `email_address` + `password_digest` (+ `has_secure_password`); fixture password is `"secret123456"`; `sign_in_as(user)` posts to `session_url`.
- `sessions` has `ip_address`, `user_agent`, `user_id`, timestamps. `Session` model is bare (`belongs_to :user`).
- `Authentication` concern (`app/controllers/concerns/authentication.rb`) provides `resume_session`, `start_new_session_for`, `terminate_session`, `after_authentication_url`.
- `SetsCurrentWorkspaceAndProject` runs `set_current_workspace, set_current_project, require_onboarding` and provides `allow_unonboarded_access`.
- `Workspace::Roles::ROLE_CAPABILITIES` maps six roles; only `owner` holds `manage_members`. `authorize_capability!` heads `:forbidden`.
- `WorkspacesController` has only `new`/`create`; routes file nests `switch` and `invitations` under `resources :workspaces`.
- AR encryption keys are already installed (Source/WebhookEndpoint use `encrypts`).
- `PruneRetentionJob` calls five existing prune class methods; prunes use `in_batches`.
- Rate-limit counters live in `Rails.cache`, cleared in test setup.
- Fixtures: users `jorge`, `owner`, `member`, `sender`, `api_keys`, `domains`, `read_only`, `outsider`; workspaces `acme` (owner: `owner`) and `globex` (owner: `outsider`); sessions fixtures exist for `owner` and `read_only` only.
- Signed cookies with `expires:` embed the expiry inside the signed payload (Rails ≥ 5.2) — server-verified, not merely browser-enforced.

---

### Task 1: `Totp` — pure-Ruby RFC 6238

**Files:**
- Create: `lib/totp.rb`
- Test: `test/lib/totp_test.rb`

**Interfaces:**
- Produces: `Totp.generate_secret` → String (32-char Base32); `Totp.new(secret)`; `#provisioning_uri(account:, issuer: "Departures")` → String; `#code(at: Time.current)` → 6-digit String; `#verify(code, at: Time.current, drift: 1)` → matched timestep Integer or nil. Consumed by Tasks 2–4.

- [ ] **Step 1: Write the failing test**

```ruby
# test/lib/totp_test.rb
require "test_helper"

class TotpTest < ActiveSupport::TestCase
  # RFC 6238 Appendix B vectors (SHA-1), truncated to 6 digits.
  # Secret is ASCII "12345678901234567890" in Base32.
  RFC_SECRET = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

  RFC_VECTORS = {
    59 => "287082",
    1_111_111_109 => "081804",
    1_111_111_111 => "050471",
    1_234_567_890 => "005924",
    2_000_000_000 => "279037"
  }.freeze

  setup do
    @totp = Totp.new(RFC_SECRET)
  end

  test "code matches the RFC 6238 test vectors" do
    RFC_VECTORS.each do |unix_time, expected|
      assert_equal expected, @totp.code(at: Time.at(unix_time)), "at T=#{unix_time}"
    end
  end

  test "verify returns the matched timestep for a current code" do
    at = Time.at(1_111_111_111)
    assert_equal 1_111_111_111 / 30, @totp.verify("050471", at: at)
  end

  test "verify accepts codes one step behind or ahead (drift window)" do
    at = Time.at(1_111_111_111)
    assert @totp.verify(@totp.code(at: at - 30), at: at)
    assert @totp.verify(@totp.code(at: at + 30), at: at)
  end

  test "verify rejects codes outside the drift window" do
    at = Time.at(1_111_111_111)
    assert_nil @totp.verify(@totp.code(at: at - 90), at: at)
    assert_nil @totp.verify(@totp.code(at: at + 90), at: at)
  end

  test "verify rejects malformed codes" do
    assert_nil @totp.verify(nil)
    assert_nil @totp.verify("")
    assert_nil @totp.verify("12345")
    assert_nil @totp.verify("abcdef")
    assert_nil @totp.verify("1234567")
  end

  test "generate_secret returns 32 Base32 characters" do
    secret = Totp.generate_secret
    assert_match(/\A[A-Z2-7]{32}\z/, secret)
    assert_not_equal secret, Totp.generate_secret
  end

  test "provisioning_uri encodes issuer and account" do
    uri = Totp.new("ABC234").provisioning_uri(account: "ann@example.com")
    assert_equal "otpauth://totp/Departures:ann%40example.com?secret=ABC234&issuer=Departures", uri
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/totp_test.rb`
Expected: FAIL — `NameError: uninitialized constant TotpTest::Totp` (or similar).

- [ ] **Step 3: Write the implementation**

```ruby
# lib/totp.rb
#
# RFC 6238 TOTP (HMAC-SHA1, 30-second step, 6 digits) — pure stdlib, no gem.
class Totp
  STEP = 30
  DIGITS = 6
  BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

  class << self
    def generate_secret
      SecureRandom.bytes(20).unpack1("B*").scan(/.{5}/).map { |chunk| BASE32_ALPHABET[chunk.to_i(2)] }.join
    end
  end

  def initialize(secret)
    @secret = secret.to_s
  end

  def provisioning_uri(account:, issuer: "Departures")
    label = "#{ERB::Util.url_encode(issuer)}:#{ERB::Util.url_encode(account)}"
    "otpauth://totp/#{label}?secret=#{@secret}&issuer=#{ERB::Util.url_encode(issuer)}"
  end

  def code(at: Time.current)
    code_at(at.to_i / STEP)
  end

  # Returns the matched timestep so callers can persist it and refuse replays.
  def verify(code, at: Time.current, drift: 1)
    if code.to_s.match?(/\A\d{#{DIGITS}}\z/)
      timestep = at.to_i / STEP

      (-drift..drift).map { |offset| timestep + offset }.find do |candidate|
        ActiveSupport::SecurityUtils.secure_compare(code_at(candidate), code.to_s)
      end
    end
  end

  private
    def code_at(timestep)
      digest = OpenSSL::HMAC.digest("SHA1", decoded_secret, [ timestep ].pack("Q>"))
      offset = digest.bytes.last & 0x0f
      binary = ((digest.bytes[offset] & 0x7f) << 24) |
        (digest.bytes[offset + 1] << 16) |
        (digest.bytes[offset + 2] << 8) |
        digest.bytes[offset + 3]

      format("%0#{DIGITS}d", binary % 10**DIGITS)
    end

    def decoded_secret
      bits = @secret.upcase.delete("=").chars.map { |char| BASE32_ALPHABET.index(char).to_s(2).rjust(5, "0") }.join
      [ bits[0, bits.length - bits.length % 8] ].pack("B*")
    end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/totp_test.rb`
Expected: PASS (8 assertions groups, 0 failures).

- [ ] **Step 5: Full suite + rubocop, then commit**

Run: `bin/rails test && bin/rubocop`

```bash
git add lib/totp.rb test/lib/totp_test.rb
git commit -m "feat: pure-Ruby RFC 6238 TOTP value object"
```

---

### Task 2: `User::TwoFactor` concern + migration

**Files:**
- Create: `db/migrate/*_add_two_factor_to_users.rb` (via generator), `app/models/user/two_factor.rb`
- Modify: `app/models/user.rb`
- Test: `test/models/user/two_factor_test.rb`

**Interfaces:**
- Consumes: `Totp` (Task 1).
- Produces on `User`: `two_factor_enabled?` / `two_factor_disabled?`, `prepare_two_factor`, `enable_two_factor(code)` → Array of 10 plaintext recovery codes or `false`, `disable_two_factor`, `verify_totp(code)` → boolean, `redeem_recovery_code(code)` → boolean, `regenerate_recovery_codes` → Array of 10 plaintext codes. Consumed by Tasks 3–5.

- [ ] **Step 1: Generate the migration**

Run:

```bash
bin/rails generate migration AddTwoFactorToUsers otp_secret:string otp_enabled_at:datetime otp_consumed_timestep:integer
```

Edit the generated migration to add the json column with defaults:

```ruby
class AddTwoFactorToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :otp_secret, :string
    add_column :users, :otp_enabled_at, :datetime
    add_column :users, :otp_consumed_timestep, :integer
    add_column :users, :otp_recovery_codes, :json, default: [], null: false
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write the failing test**

```ruby
# test/models/user/two_factor_test.rb
require "test_helper"

class User::TwoFactorTest < ActiveSupport::TestCase
  setup do
    @user = users(:jorge)
    @user.prepare_two_factor
    @totp = Totp.new(@user.otp_secret)
  end

  test "prepare_two_factor stores an encrypted secret while still disabled" do
    assert @user.otp_secret.present?
    assert @user.two_factor_disabled?
    assert_not_equal @user.otp_secret, @user.read_attribute_before_type_cast(:otp_secret)
  end

  test "enable_two_factor with a valid code enables and returns ten recovery codes" do
    codes = @user.enable_two_factor(@totp.code)

    assert @user.two_factor_enabled?
    assert_equal 10, codes.length
    assert_equal 10, @user.otp_recovery_codes.length
    codes.each { |code| assert_not_includes @user.otp_recovery_codes, code } # digests stored, not plaintext
  end

  test "enable_two_factor with an invalid code returns false and stays disabled" do
    assert_equal false, @user.enable_two_factor("000000")
    assert @user.two_factor_disabled?
  end

  test "verify_totp accepts a fresh code once and refuses its replay" do
    @user.enable_two_factor(@totp.code)
    fresh = @totp.code(at: 1.minute.from_now)

    assert @user.verify_totp(fresh, at: 1.minute.from_now)
    assert_not @user.verify_totp(fresh, at: 1.minute.from_now)
  end

  test "verify_totp refuses codes when disabled" do
    assert_not @user.verify_totp(@totp.code)
  end

  test "redeem_recovery_code consumes a code exactly once" do
    codes = @user.enable_two_factor(@totp.code)

    assert @user.redeem_recovery_code(codes.first)
    assert_not @user.redeem_recovery_code(codes.first)
    assert_equal 9, @user.otp_recovery_codes.length
  end

  test "redeem_recovery_code refuses unknown codes" do
    @user.enable_two_factor(@totp.code)
    assert_not @user.redeem_recovery_code("nope")
  end

  test "regenerate_recovery_codes invalidates the old set" do
    old_codes = @user.enable_two_factor(@totp.code)
    new_codes = @user.regenerate_recovery_codes

    assert_not @user.redeem_recovery_code(old_codes.first)
    assert @user.redeem_recovery_code(new_codes.first)
  end

  test "disable_two_factor clears everything" do
    @user.enable_two_factor(@totp.code)
    @user.disable_two_factor

    assert @user.two_factor_disabled?
    assert_nil @user.otp_secret
    assert_nil @user.otp_consumed_timestep
    assert_empty @user.otp_recovery_codes
  end
end
```

Note: `verify_totp` takes an optional `at:` keyword (defaulting to `Time.current`) purely so tests can step time without freezing helpers.

- [ ] **Step 3: Run test to verify it fails**

Run: `bin/rails test test/models/user/two_factor_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'prepare_two_factor'`.

- [ ] **Step 4: Write the concern and include it**

```ruby
# app/models/user/two_factor.rb
module User::TwoFactor
  extend ActiveSupport::Concern

  RECOVERY_CODE_COUNT = 10

  included do
    encrypts :otp_secret
  end

  def two_factor_enabled?
    otp_enabled_at.present?
  end

  def two_factor_disabled?
    !two_factor_enabled?
  end

  def prepare_two_factor
    update! otp_secret: Totp.generate_secret
  end

  def enable_two_factor(code)
    timestep = otp_secret.present? && totp.verify(code)

    if timestep
      codes = build_recovery_codes
      update! otp_enabled_at: Time.current, otp_consumed_timestep: timestep, otp_recovery_codes: digest_codes(codes)
      codes
    else
      false
    end
  end

  def disable_two_factor
    update! otp_secret: nil, otp_enabled_at: nil, otp_consumed_timestep: nil, otp_recovery_codes: []
  end

  def verify_totp(code, at: Time.current)
    if two_factor_enabled?
      timestep = totp.verify(code, at: at)

      if timestep && timestep > otp_consumed_timestep.to_i
        update! otp_consumed_timestep: timestep
        true
      else
        false
      end
    else
      false
    end
  end

  def redeem_recovery_code(code)
    digest = Digest::SHA256.hexdigest(code.to_s.strip)

    if otp_recovery_codes.include?(digest)
      update! otp_recovery_codes: otp_recovery_codes - [ digest ]
      true
    else
      false
    end
  end

  def regenerate_recovery_codes
    codes = build_recovery_codes
    update! otp_recovery_codes: digest_codes(codes)
    codes
  end

  private
    def totp
      Totp.new(otp_secret)
    end

    def build_recovery_codes
      Array.new(RECOVERY_CODE_COUNT) { SecureRandom.hex(5) }
    end

    def digest_codes(codes)
      codes.map { |code| Digest::SHA256.hexdigest(code) }
    end
end
```

```ruby
# app/models/user.rb — add below has_secure_password
class User < ApplicationRecord
  include TwoFactor

  has_secure_password
  # ... rest unchanged
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/models/user/two_factor_test.rb`
Expected: PASS.

- [ ] **Step 6: Full suite + rubocop, then commit**

Run: `bin/rails test && bin/rubocop`

```bash
git add db/migrate db/schema.rb app/models/user.rb app/models/user/two_factor.rb test/models/user/two_factor_test.rb
git commit -m "feat: User::TwoFactor — encrypted TOTP secret, replay guard, recovery codes"
```

---

### Task 3: 2FA enrollment — controllers, views, vendored QR

**Files:**
- Create: `app/controllers/users/two_factors_controller.rb`, `app/controllers/users/recovery_codes_controller.rb`, `app/views/users/two_factors/new.html.erb`, `app/views/users/two_factors/create.html.erb`, `app/views/users/recovery_codes/create.html.erb`, `app/javascript/controllers/qr_code_controller.js`
- Modify: `config/routes.rb`, `config/importmap.rb` (via `bin/importmap pin`)
- Test: `test/controllers/users/two_factors_controller_test.rb`

**Interfaces:**
- Consumes: `User::TwoFactor` (Task 2), `Totp#provisioning_uri` (Task 1).
- Produces: routes `new_two_factor_path` (GET /two_factor/new), `two_factor_path` (POST/DELETE /two_factor), `recovery_codes_path` (POST /recovery_codes). Both controllers declare `allow_unonboarded_access` (and, from Task 5 onward, `allow_two_factor_unenrolled_access`).

- [ ] **Step 1: Vendor the QR encoder**

Run:

```bash
bin/importmap pin qrcode-generator
```

Expected: downloads `qrcode-generator` into `vendor/javascript/` and adds a `pin "qrcode-generator" ...` line to `config/importmap.rb`. Verify with `bin/importmap audit` (green) and `git status` (new vendor file).

- [ ] **Step 2: Write the Stimulus controller**

```javascript
// app/javascript/controllers/qr_code_controller.js
import { Controller } from "@hotwired/stimulus"
import qrcode from "qrcode-generator"

// Renders the value of data-qr-code-text-value as an inline SVG QR code.
export default class extends Controller {
  static values = { text: String }

  connect() {
    const qr = qrcode(0, "M")
    qr.addData(this.textValue)
    qr.make()
    this.element.innerHTML = qr.createSvgTag({ cellSize: 4, margin: 2, scalable: true })
  }
}
```

- [ ] **Step 3: Add routes**

In `config/routes.rb`, below the `resources :passwords` line:

```ruby
scope module: :users do
  resource :two_factor, only: %i[ new create destroy ]
  resource :recovery_codes, only: :create
end
```

- [ ] **Step 4: Write the failing controller test**

```ruby
# test/controllers/users/two_factors_controller_test.rb
require "test_helper"

class Users::TwoFactorsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:owner)
    sign_in_as @user
  end

  test "new prepares a secret and shows the provisioning details" do
    get new_two_factor_path

    assert_response :success
    assert @user.reload.otp_secret.present?
    assert @user.two_factor_disabled?
    assert_match "otpauth://totp/", response.body
  end

  test "create with correct password and code enables 2FA and reveals recovery codes once" do
    get new_two_factor_path
    code = Totp.new(@user.reload.otp_secret).code

    post two_factor_path, params: { password: "secret123456", code: code }

    assert_response :success
    assert @user.reload.two_factor_enabled?
    assert_select "code", minimum: 10
  end

  test "create with wrong password does not enable" do
    get new_two_factor_path
    code = Totp.new(@user.reload.otp_secret).code

    post two_factor_path, params: { password: "wrong", code: code }

    assert_redirected_to new_two_factor_path
    assert @user.reload.two_factor_disabled?
  end

  test "create with wrong code does not enable" do
    get new_two_factor_path

    post two_factor_path, params: { password: "secret123456", code: "000000" }

    assert_redirected_to new_two_factor_path
    assert @user.reload.two_factor_disabled?
  end

  test "destroy with correct password disables 2FA" do
    enable_two_factor_for @user

    delete two_factor_path, params: { password: "secret123456" }

    assert_redirected_to root_path
    assert @user.reload.two_factor_disabled?
  end

  test "destroy with wrong password keeps 2FA on" do
    enable_two_factor_for @user

    delete two_factor_path, params: { password: "wrong" }

    assert @user.reload.two_factor_enabled?
  end

  test "recovery codes can be regenerated with password" do
    enable_two_factor_for @user
    old_digests = @user.reload.otp_recovery_codes

    post recovery_codes_path, params: { password: "secret123456" }

    assert_response :success
    assert_not_equal old_digests, @user.reload.otp_recovery_codes
  end
end
```

The test uses a shared helper — add it to `test/test_helper.rb` inside `ActiveSupport::TestCase` (later tasks reuse it from both model and integration tests):

```ruby
# test/test_helper.rb — add below wipe_workspace_records inside class TestCase
    # Enables TOTP for a user and returns the plaintext recovery codes.
    def enable_two_factor_for(user)
      user.prepare_two_factor
      user.enable_two_factor(Totp.new(user.otp_secret).code)
    end
```

- [ ] **Step 5: Run test to verify it fails**

Run: `bin/rails test test/controllers/users/two_factors_controller_test.rb`
Expected: FAIL — routing/controller errors.

- [ ] **Step 6: Write the controllers**

```ruby
# app/controllers/users/two_factors_controller.rb
class Users::TwoFactorsController < ApplicationController
  allow_unonboarded_access

  def new
    unless Current.user.two_factor_enabled?
      Current.user.prepare_two_factor
    end
    @totp = Totp.new(Current.user.otp_secret)
  end

  def create
    if Current.user.authenticate(params[:password]) && (@recovery_codes = Current.user.enable_two_factor(params[:code]))
      render :create
    else
      redirect_to new_two_factor_path, alert: "Wrong password or code. Scan the QR code again and retry."
    end
  end

  def destroy
    if Current.user.authenticate(params[:password])
      Current.user.disable_two_factor
      redirect_to root_path, notice: "Two-factor authentication disabled."
    else
      redirect_to root_path, alert: "Wrong password — two-factor authentication is still enabled."
    end
  end
end
```

```ruby
# app/controllers/users/recovery_codes_controller.rb
class Users::RecoveryCodesController < ApplicationController
  allow_unonboarded_access

  def create
    if Current.user.two_factor_enabled? && Current.user.authenticate(params[:password])
      @recovery_codes = Current.user.regenerate_recovery_codes
      render :create
    else
      redirect_to root_path, alert: "Wrong password — recovery codes unchanged."
    end
  end
end
```

- [ ] **Step 7: Write the views**

```erb
<%# app/views/users/two_factors/new.html.erb %>
<% content_for :title, "Enable two-factor authentication" %>

<h1>Enable two-factor authentication</h1>

<p>Scan this QR code with your authenticator app, then confirm with the 6-digit code it shows.</p>

<div data-controller="qr-code" data-qr-code-text-value="<%= @totp.provisioning_uri(account: Current.user.email_address) %>"
  style="max-inline-size: 14rem;"></div>

<p>Can't scan? Enter this secret manually: <code><%= Current.user.otp_secret %></code></p>

<%= form_with url: two_factor_path do |form| %>
  <%= form.password_field :password, required: true, autocomplete: "current-password", placeholder: "Your password", class: "input" %>
  <%= form.text_field :code, required: true, autocomplete: "one-time-code", inputmode: "numeric", pattern: "\\d{6}", placeholder: "6-digit code", class: "input" %>
  <%= form.submit "Enable two-factor", class: "btn btn--primary btn--medium" %>
<% end %>
```

```erb
<%# app/views/users/two_factors/create.html.erb %>
<% content_for :title, "Recovery codes" %>

<h1>Two-factor authentication enabled</h1>

<div class="secret-reveal">
  <p>These recovery codes are shown <strong>only once</strong>. Each works a single time if you lose your authenticator.</p>
  <ul>
    <% @recovery_codes.each do |code| %>
      <li><code><%= code %></code></li>
    <% end %>
  </ul>
  <button type="button" class="btn btn--secondary btn--medium" data-controller="clipboard"
    data-clipboard-text-value="<%= @recovery_codes.join("\n") %>" data-action="clipboard#copy">
    Copy all codes
  </button>
</div>

<p><%= link_to "Done", root_path, class: "btn btn--plain btn--medium" %></p>
```

```erb
<%# app/views/users/recovery_codes/create.html.erb %>
<% content_for :title, "Recovery codes" %>

<h1>New recovery codes</h1>

<div class="secret-reveal">
  <p>Your old codes no longer work. These are shown <strong>only once</strong>.</p>
  <ul>
    <% @recovery_codes.each do |code| %>
      <li><code><%= code %></code></li>
    <% end %>
  </ul>
  <button type="button" class="btn btn--secondary btn--medium" data-controller="clipboard"
    data-clipboard-text-value="<%= @recovery_codes.join("\n") %>" data-action="clipboard#copy">
    Copy all codes
  </button>
</div>

<p><%= link_to "Done", root_path, class: "btn btn--plain btn--medium" %></p>
```

- [ ] **Step 8: Run test to verify it passes**

Run: `bin/rails test test/controllers/users/two_factors_controller_test.rb`
Expected: PASS.

- [ ] **Step 9: Full suite + rubocop, visual check, then commit**

Run: `bin/rails test && bin/rubocop`. Boot `bin/dev`, sign in, visit `/two_factor/new`, confirm the QR renders in light and dark themes.

```bash
git add config/routes.rb config/importmap.rb vendor/javascript app/javascript/controllers/qr_code_controller.js \
  app/controllers/users app/views/users test/controllers/users test/test_helper.rb
git commit -m "feat: 2FA enrollment with client-side QR and one-time recovery code reveal"
```

---

### Task 4: Login challenge

**Files:**
- Modify: `app/controllers/sessions_controller.rb`, `config/routes.rb`
- Create: `app/controllers/sessions/challenges_controller.rb`, `app/views/sessions/challenges/new.html.erb`
- Test: `test/controllers/sessions/challenges_controller_test.rb`, extend `test/controllers/sessions_controller_test.rb`

**Interfaces:**
- Consumes: `User#two_factor_enabled?`, `#verify_totp`, `#redeem_recovery_code` (Task 2); `start_new_session_for` / `after_authentication_url` (Authentication concern).
- Produces: routes `new_challenge_path` (GET /challenge/new), `challenge_path` (POST /challenge); signed cookie `:pending_two_factor_user_id` (10-minute server-verified expiry) written by `SessionsController#create`, consumed and deleted by the challenge.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/controllers/sessions/challenges_controller_test.rb
require "test_helper"

class Sessions::ChallengesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:jorge)
    @codes = enable_two_factor_for(@user)
  end

  test "password login for a 2FA user creates no session and redirects to the challenge" do
    post session_path, params: { email_address: @user.email_address, password: "secret123456" }

    assert_redirected_to new_challenge_path
    assert_nil cookies[:session_id].presence
  end

  test "challenge with a valid TOTP creates the session" do
    start_challenge
    travel 1.minute do
      post challenge_path, params: { code: Totp.new(@user.reload.otp_secret).code }
    end

    assert_redirected_to root_path
    assert cookies[:session_id].present?
  end

  test "challenge with a recovery code creates the session and consumes the code" do
    start_challenge

    post challenge_path, params: { code: @codes.first }

    assert_redirected_to root_path
    assert cookies[:session_id].present?
    assert_equal 9, @user.reload.otp_recovery_codes.length
  end

  test "challenge with an invalid code re-renders and creates no session" do
    start_challenge

    post challenge_path, params: { code: "000000" }

    assert_redirected_to new_challenge_path
    assert_nil cookies[:session_id].presence
  end

  test "challenge without a pending login redirects to sign-in" do
    get new_challenge_path
    assert_redirected_to new_session_path
  end

  test "challenge is rate limited" do
    start_challenge

    11.times { post challenge_path, params: { code: "000000" } }

    assert_redirected_to new_challenge_path
    assert_equal "Try again later.", flash[:alert]
    assert_nil cookies[:session_id].presence
  end

  test "non-2FA users still log in in one step" do
    plain = users(:member)

    post session_path, params: { email_address: plain.email_address, password: "secret123456" }

    assert_redirected_to root_path
    assert cookies[:session_id].present?
  end

  private
    def start_challenge
      post session_path, params: { email_address: @user.email_address, password: "secret123456" }
    end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/sessions/challenges_controller_test.rb`
Expected: FAIL — no `new_challenge_path` route.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, below `resource :session`:

```ruby
resource :challenge, only: %i[ new create ], controller: "sessions/challenges"
```

- [ ] **Step 4: Modify `SessionsController#create` and add the challenge controller**

```ruby
# app/controllers/sessions_controller.rb — replace create; add private section
  def create
    if user = User.authenticate_by(params.permit(:email_address, :password))
      if user.two_factor_enabled?
        stash_pending_two_factor user
        redirect_to new_challenge_path
      else
        start_new_session_for user
        redirect_to after_authentication_url
      end
    else
      redirect_to new_session_path, alert: "Try another email address or password."
    end
  end

  # ... destroy unchanged ...

  private
    def stash_pending_two_factor(user)
      cookies.signed[:pending_two_factor_user_id] = {
        value: user.id, expires: 10.minutes, httponly: true, same_site: :lax
      }
    end
```

```ruby
# app/controllers/sessions/challenges_controller.rb
class Sessions::ChallengesController < ApplicationController
  allow_unauthenticated_access
  allow_unonboarded_access
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_challenge_path, alert: "Try again later." }
  before_action :set_pending_user

  def new
  end

  def create
    if @user.verify_totp(params[:code]) || @user.redeem_recovery_code(params[:code])
      cookies.delete(:pending_two_factor_user_id)
      start_new_session_for @user
      redirect_to after_authentication_url
    else
      redirect_to new_challenge_path, alert: "That code didn't work. Try the current code from your app, or a recovery code."
    end
  end

  private
    def set_pending_user
      @user = User.find_by(id: cookies.signed[:pending_two_factor_user_id])

      if @user.nil?
        redirect_to new_session_path, alert: "Please sign in again."
      end
    end
end
```

```erb
<%# app/views/sessions/challenges/new.html.erb %>
<% content_for :title, "Two-factor code" %>

<h1>Enter your two-factor code</h1>

<%= form_with url: challenge_path do |form| %>
  <%= form.text_field :code, required: true, autofocus: true, autocomplete: "one-time-code", inputmode: "numeric",
    placeholder: "6-digit or recovery code", class: "input" %>
  <%= form.submit "Verify", class: "btn btn--primary btn--medium" %>
<% end %>

<p>Lost your device? Enter one of your recovery codes instead.</p>
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/controllers/sessions/challenges_controller_test.rb test/controllers/sessions_controller_test.rb`
Expected: PASS (existing sessions tests must stay green — the fixture users have no 2FA).

- [ ] **Step 6: Full suite + rubocop, then commit**

Run: `bin/rails test && bin/rubocop`

```bash
git add app/controllers/sessions_controller.rb app/controllers/sessions app/views/sessions/challenges \
  config/routes.rb test/controllers/sessions
git commit -m "feat: two-step login challenge for 2FA users (TOTP or recovery code)"
```

---

### Task 5: Workspace 2FA enforcement

**Files:**
- Create: `db/migrate/*_add_require_two_factor_to_workspaces.rb`, `app/views/workspaces/edit.html.erb`
- Modify: `app/controllers/concerns/sets_current_workspace_and_project.rb`, `app/controllers/workspaces_controller.rb`, `app/controllers/sessions_controller.rb`, `app/controllers/passwords_controller.rb`, `app/controllers/registrations_controller.rb`, `app/controllers/sessions/challenges_controller.rb`, `app/controllers/users/two_factors_controller.rb`, `app/controllers/users/recovery_codes_controller.rb`, `app/controllers/workspaces/switches_controller.rb`, `config/routes.rb`, `app/views/layouts/_nav.html.erb`
- Test: `test/controllers/two_factor_enforcement_test.rb`, extend `test/controllers/workspaces_controller_test.rb`

**Interfaces:**
- Consumes: `User#two_factor_disabled?` (Task 2), `authorize_capability!`.
- Produces: `workspaces.require_two_factor` boolean; `SetsCurrentWorkspaceAndProject.allow_two_factor_unenrolled_access` class method; routes `edit_workspace_path`/`workspace_path` (PATCH). Task 8 later instruments the toggle with audit events.

- [ ] **Step 1: Migration**

```bash
bin/rails generate migration AddRequireTwoFactorToWorkspaces
```

```ruby
class AddRequireTwoFactorToWorkspaces < ActiveRecord::Migration[8.1]
  def change
    add_column :workspaces, :require_two_factor, :boolean, default: false, null: false
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write the failing tests**

```ruby
# test/controllers/two_factor_enforcement_test.rb
require "test_helper"

class TwoFactorEnforcementTest < ActionDispatch::IntegrationTest
  setup do
    workspaces(:acme).update!(require_two_factor: true)
    @user = users(:member)
    sign_in_as @user
  end

  test "an unenrolled member of an enforcing workspace is redirected to enrollment" do
    get root_path
    assert_redirected_to new_two_factor_path
  end

  test "the enrollment screens themselves stay reachable (no redirect loop)" do
    get new_two_factor_path
    assert_response :success
  end

  test "sign-out stays reachable" do
    delete session_path
    assert_redirected_to new_session_path
  end

  test "an enrolled member passes through" do
    enable_two_factor_for @user

    get root_path
    assert_response :success
  end

  test "a member of a non-enforcing workspace is unaffected" do
    workspaces(:acme).update!(require_two_factor: false)

    get root_path
    assert_response :success
  end
end
```

Add to `test/controllers/workspaces_controller_test.rb`:

```ruby
  test "owner can toggle require_two_factor" do
    sign_in_as users(:owner)

    patch workspace_path(workspaces(:acme)), params: { workspace: { require_two_factor: true } }

    assert_redirected_to edit_workspace_path(workspaces(:acme))
    assert workspaces(:acme).reload.require_two_factor?
  end

  test "non-owner cannot update the workspace" do
    sign_in_as users(:member)

    patch workspace_path(workspaces(:acme)), params: { workspace: { require_two_factor: true } }

    assert_response :forbidden
    assert_not workspaces(:acme).reload.require_two_factor?
  end

  test "updating a foreign workspace 404s" do
    sign_in_as users(:owner)

    patch workspace_path(workspaces(:globex)), params: { workspace: { require_two_factor: true } }

    assert_response :not_found
  end
```

Note on the enforcement test: `users(:member)` signing in while enforcement is on will be redirected on every dashboard hit — `sign_in_as` still works because `SessionsController` is exempt.

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/controllers/two_factor_enforcement_test.rb test/controllers/workspaces_controller_test.rb`
Expected: FAIL — no gate, no `edit`/`update` route.

- [ ] **Step 4: Implement the gate**

```ruby
# app/controllers/concerns/sets_current_workspace_and_project.rb — full replacement
module SetsCurrentWorkspaceAndProject
  extend ActiveSupport::Concern

  included do
    before_action :set_current_workspace, :set_current_project, :require_two_factor_enrollment, :require_onboarding
  end

  class_methods do
    def allow_unonboarded_access(**options)
      skip_before_action :require_onboarding, **options
    end

    def allow_two_factor_unenrolled_access(**options)
      skip_before_action :require_two_factor_enrollment, **options
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

    def require_two_factor_enrollment
      if Current.workspace&.require_two_factor? && Current.user&.two_factor_disabled?
        redirect_to new_two_factor_path, alert: "#{Current.workspace.name} requires two-factor authentication. Enable it to continue."
      end
    end

    def require_onboarding
      if Current.workspace&.needs_onboarding?
        redirect_to onboarding_path
      end
    end
end
```

Add `allow_two_factor_unenrolled_access` to each of these controllers (right next to their existing `allow_*` lines): `SessionsController`, `PasswordsController`, `RegistrationsController`, `Sessions::ChallengesController`, `Users::TwoFactorsController`, `Users::RecoveryCodesController`, `Workspaces::SwitchesController`, `WorkspacesController`.

- [ ] **Step 5: Workspace settings (edit/update) + nav**

Routes — change the workspaces line:

```ruby
resources :workspaces, only: %i[ new create edit update ] do
```

```ruby
# app/controllers/workspaces_controller.rb — add below allow_unonboarded_access
  before_action :set_workspace, only: %i[ edit update ]

# add below create
  def edit
  end

  def update
    if @workspace.update(settings_params)
      redirect_to edit_workspace_path(@workspace), notice: "Workspace settings saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    def set_workspace
      @workspace = Current.user.workspaces.find(params[:id])
      authorize_capability! :manage_members, workspace: @workspace
    end

    def workspace_params
      params.expect(workspace: [ :name ])
    end

    def settings_params
      params.expect(workspace: [ :name, :require_two_factor ])
    end
```

(`set_workspace` must run as a `before_action` — `authorize_capability!` halts the chain only from a before_action, since it just renders `head :forbidden`. The tenancy scope 404s first for foreign workspaces.)

```erb
<%# app/views/workspaces/edit.html.erb %>
<% content_for :title, "Workspace settings" %>

<h1>Workspace settings</h1>

<%= form_with model: @workspace do |form| %>
  <%= form.label :name %>
  <%= form.text_field :name, required: true, class: "input" %>

  <label class="flex align-center gap">
    <%= form.check_box :require_two_factor %>
    Require two-factor authentication for every member of this workspace
  </label>

  <%= form.submit "Save settings", class: "btn btn--primary btn--medium" %>
<% end %>
```

Add to `app/views/layouts/_nav.html.erb`, after the "API keys" link:

```erb
  <% if Current.workspace&.capability?(Current.user, :manage_members) %>
    <%= link_to "Workspace", edit_workspace_path(Current.workspace), class: "nav__link", aria: { current: current_page?(edit_workspace_path(Current.workspace)) ? "page" : nil } %>
  <% end %>
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bin/rails test test/controllers/two_factor_enforcement_test.rb test/controllers/workspaces_controller_test.rb`
Expected: PASS.

- [ ] **Step 7: Full suite + rubocop, then commit**

Run: `bin/rails test && bin/rubocop`

```bash
git add db/migrate db/schema.rb app/controllers app/views config/routes.rb test/controllers
git commit -m "feat: per-workspace 2FA enforcement with workspace settings page"
```

---

### Task 6: Session management

**Files:**
- Create: `db/migrate/*_add_last_active_at_to_sessions.rb`, `app/controllers/other_sessions_controller.rb`, `app/views/sessions/index.html.erb`
- Modify: `app/models/session.rb`, `app/controllers/concerns/authentication.rb` (one line in `resume_session`), `app/controllers/sessions_controller.rb`, `config/routes.rb`, `app/views/layouts/_nav.html.erb`
- Test: `test/controllers/sessions_management_test.rb`, `test/models/session_test.rb`

**Interfaces:**
- Consumes: `Current.user.sessions`, `terminate_session` (Authentication concern).
- Produces: routes `user_sessions_path` (GET /sessions), `user_session_path(id)` (DELETE /sessions/:id), `other_sessions_path` (DELETE /other_sessions); `Session#touch_activity`, `Session#device_summary`, `Session#current?`. Task 8 instruments revocations with audit events.

- [ ] **Step 1: Migration**

```bash
bin/rails generate migration AddLastActiveAtToSessions last_active_at:datetime
bin/rails db:migrate
```

- [ ] **Step 2: Write the failing tests**

```ruby
# test/models/session_test.rb
require "test_helper"

class SessionTest < ActiveSupport::TestCase
  test "touch_activity stamps at most once per minute" do
    session = sessions(:owner)

    session.touch_activity
    first = session.reload.last_active_at
    assert first.present?

    session.touch_activity
    assert_equal first, session.reload.last_active_at

    session.update_column(:last_active_at, 2.minutes.ago)
    session.touch_activity
    assert session.reload.last_active_at > first - 1.minute
  end

  test "device_summary names browser and platform" do
    session = Session.new(user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36")
    assert_equal "Chrome on macOS", session.device_summary

    assert_equal "Unknown device", Session.new(user_agent: nil).device_summary
  end
end
```

```ruby
# test/controllers/sessions_management_test.rb
require "test_helper"

class SessionsManagementTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:owner)
    sign_in_as @user
  end

  test "index lists only my sessions" do
    get user_sessions_path

    assert_response :success
    assert_match "Minitest", response.body
  end

  test "index touches activity on the current session" do
    get user_sessions_path
    assert @user.sessions.order(created_at: :desc).first.last_active_at.present?
  end

  test "revoking another of my sessions keeps me signed in" do
    other = @user.sessions.create!(user_agent: "OtherBrowser", ip_address: "10.0.0.1")

    delete user_session_path(other)

    assert_redirected_to user_sessions_path
    assert_not Session.exists?(other.id)
    get user_sessions_path
    assert_response :success
  end

  test "revoking my current session signs me out" do
    current = @user.sessions.order(created_at: :desc).first

    delete user_session_path(current)

    assert_redirected_to new_session_path
    get user_sessions_path
    assert_redirected_to new_session_path
  end

  test "revoking a foreign session 404s" do
    delete user_session_path(sessions(:read_only))
    assert_response :not_found
  end

  test "other_sessions destroy removes everything but the current session" do
    @user.sessions.create!(user_agent: "OtherBrowser", ip_address: "10.0.0.1")
    @user.sessions.create!(user_agent: "ThirdBrowser", ip_address: "10.0.0.2")

    delete other_sessions_path

    assert_redirected_to user_sessions_path
    assert_equal 1, @user.sessions.count
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/models/session_test.rb test/controllers/sessions_management_test.rb`
Expected: FAIL.

- [ ] **Step 4: Implement**

```ruby
# app/models/session.rb
class Session < ApplicationRecord
  belongs_to :user

  scope :by_recent_activity, -> { order(Arel.sql("COALESCE(last_active_at, created_at) DESC"), id: :desc) }

  BROWSERS = { "Edg" => "Edge", "OPR" => "Opera", "Firefox" => "Firefox", "Chrome" => "Chrome", "Safari" => "Safari" }.freeze
  PLATFORMS = { "iPhone" => "iOS", "iPad" => "iPadOS", "Android" => "Android", "Windows" => "Windows",
    "Macintosh" => "macOS", "Mac OS X" => "macOS", "Linux" => "Linux" }.freeze

  def touch_activity
    if last_active_at.nil? || last_active_at < 1.minute.ago
      update_column(:last_active_at, Time.current)
    end
  end

  def current?
    self == Current.session
  end

  def device_summary
    if user_agent.blank?
      "Unknown device"
    else
      browser = BROWSERS.find { |token, _| user_agent.include?(token) }&.last
      platform = PLATFORMS.find { |token, _| user_agent.include?(token) }&.last
      [ browser, platform ].compact.join(" on ").presence || user_agent.truncate(40)
    end
  end
end
```

```ruby
# app/controllers/concerns/authentication.rb — replace resume_session
    def resume_session
      Current.session ||= find_session_by_cookie
      Current.session&.touch_activity
      Current.session
    end
```

```ruby
# app/controllers/sessions_controller.rb — add index; replace destroy
  def index
    @sessions = Current.user.sessions.by_recent_activity
  end

  def destroy
    session_record = params[:id] ? Current.user.sessions.find(params[:id]) : Current.session

    if session_record == Current.session
      terminate_session
      redirect_to new_session_path, status: :see_other
    else
      session_record.destroy
      redirect_to user_sessions_path, notice: "Session signed out."
    end
  end
```

```ruby
# app/controllers/other_sessions_controller.rb
class OtherSessionsController < ApplicationController
  allow_unonboarded_access

  def destroy
    Current.user.sessions.where.not(id: Current.session.id).destroy_all
    redirect_to user_sessions_path, notice: "Signed out everywhere else."
  end
end
```

Routes — below `resource :challenge ...`:

```ruby
resources :sessions, only: %i[ index destroy ], as: :user_sessions
resource :other_sessions, only: :destroy, controller: "other_sessions"
```

(`as: :user_sessions` avoids a helper-name collision with the singular `resource :session`.)

```erb
<%# app/views/sessions/index.html.erb %>
<% content_for :title, "Security" %>

<h1>Security</h1>

<section>
  <h2>Two-factor authentication</h2>
  <% if Current.user.two_factor_enabled? %>
    <p>Two-factor authentication is <strong>enabled</strong>.</p>
    <%= form_with url: recovery_codes_path do |form| %>
      <%= form.password_field :password, required: true, autocomplete: "current-password", placeholder: "Your password", class: "input" %>
      <%= form.submit "Regenerate recovery codes", class: "btn btn--secondary btn--medium" %>
    <% end %>
    <%= form_with url: two_factor_path, method: :delete do |form| %>
      <%= form.password_field :password, required: true, autocomplete: "current-password", placeholder: "Your password", class: "input" %>
      <%= form.submit "Disable two-factor", class: "btn btn--destroy btn--medium" %>
    <% end %>
  <% else %>
    <p>Two-factor authentication is <strong>off</strong>.</p>
    <%= link_to "Enable two-factor authentication", new_two_factor_path, class: "btn btn--primary btn--medium" %>
  <% end %>
</section>

<section>
  <h2>Sessions</h2>
  <table>
    <thead>
      <tr><th>Device</th><th>IP</th><th>Signed in</th><th>Last active</th><th></th></tr>
    </thead>
    <tbody>
      <% @sessions.each do |session_record| %>
        <tr>
          <td><%= session_record.device_summary %><%= " (this device)" if session_record.current? %></td>
          <td><%= session_record.ip_address %></td>
          <td><%= session_record.created_at.to_fs(:short) %></td>
          <td><%= session_record.last_active_at&.to_fs(:short) || "—" %></td>
          <td>
            <% unless session_record.current? %>
              <%= button_to "Sign out", user_session_path(session_record), method: :delete, class: "btn btn--plain btn--medium" %>
            <% end %>
          </td>
        </tr>
      <% end %>
    </tbody>
  </table>
  <%= button_to "Sign out everywhere else", other_sessions_path, method: :delete, class: "btn btn--secondary btn--medium" %>
</section>
```

Add to `_nav.html.erb`, after the "Send test" link:

```erb
  <%= link_to "Security", user_sessions_path, class: "nav__link", aria: { current: current_page?(user_sessions_path) ? "page" : nil } %>
```

- [ ] **Step 5: Run tests, full suite, rubocop, commit**

Run: `bin/rails test test/models/session_test.rb test/controllers/sessions_management_test.rb && bin/rails test && bin/rubocop`

```bash
git add db/migrate db/schema.rb app/models/session.rb app/controllers app/views config/routes.rb test
git commit -m "feat: session management — activity tracking, per-session and bulk revocation"
```

---

### Task 7: `AuditEvent` model + `Current.ip` + retention

**Files:**
- Create: `db/migrate/*_create_audit_events.rb`, `app/models/audit_event.rb`
- Modify: `app/models/current.rb`, `app/controllers/application_controller.rb`, `app/models/workspace.rb`, `app/jobs/prune_retention_job.rb`
- Test: `test/models/audit_event_test.rb`

**Interfaces:**
- Consumes: `Current` attributes.
- Produces: `AuditEvent.record(action, subject: nil, metadata: {}, workspace: Current.workspace, user: Current.user)` → AuditEvent; `AuditEvent::ACTIONS` allowlist; scopes `reverse_chronologically`, `preloaded`, `indexed_by(group)`, `in_time_range(range)`; `AuditEvent.prune` (180 days); `Current.ip`. Consumed by Tasks 8–9.

- [ ] **Step 1: Migration**

```bash
bin/rails generate migration CreateAuditEvents
```

```ruby
class CreateAuditEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :audit_events do |t|
      t.belongs_to :workspace
      t.belongs_to :user
      t.string :action, null: false
      t.references :subject, polymorphic: true
      t.json :metadata, default: {}, null: false
      t.string :ip
      t.datetime :created_at, null: false

      t.index %i[ workspace_id created_at ]
      t.index %i[ workspace_id action ]
    end
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write the failing test**

```ruby
# test/models/audit_event_test.rb
require "test_helper"

class AuditEventTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    Current.workspace = workspaces(:acme)
    Current.ip = "203.0.113.7"
  end

  teardown do
    Current.reset
  end

  test "record captures actor, workspace and ip from Current" do
    event = AuditEvent.record("api_key.revoked", subject: api_keys(:acme_full), metadata: { prefix: "dp_abc" })

    assert_equal users(:owner), event.user
    assert_equal workspaces(:acme), event.workspace
    assert_equal "203.0.113.7", event.ip
    assert_equal api_keys(:acme_full), event.subject
    assert_equal "dp_abc", event.metadata["prefix"]
  end

  test "record tolerates a missing workspace and user" do
    Current.reset

    event = AuditEvent.record("two_factor.recovery_code_redeemed")

    assert_nil event.workspace
    assert_nil event.user
  end

  test "record refuses unknown actions" do
    assert_raises ActiveRecord::RecordInvalid do
      AuditEvent.record("made_up.action")
    end
  end

  test "indexed_by and in_time_range narrow the list" do
    AuditEvent.record("api_key.revoked")
    AuditEvent.record("two_factor.enabled")
    AuditEvent.record("domain.created").update_column(:created_at, 8.days.ago)

    assert_equal 1, AuditEvent.indexed_by("api_keys").count
    assert_equal 1, AuditEvent.indexed_by("security").count
    assert_equal 3, AuditEvent.indexed_by(nil).count
    assert_equal 2, AuditEvent.in_time_range("7d").count
  end

  test "prune removes events older than 180 days" do
    fresh = AuditEvent.record("api_key.revoked")
    stale = AuditEvent.record("api_key.revoked")
    stale.update_column(:created_at, 181.days.ago)

    AuditEvent.prune

    assert AuditEvent.exists?(fresh.id)
    assert_not AuditEvent.exists?(stale.id)
  end
end
```

(Fixture names verified: `api_keys(:acme_full)`, `sessions(:owner)`, `workspaces(:acme)` all exist.)

- [ ] **Step 3: Run test to verify it fails**

Run: `bin/rails test test/models/audit_event_test.rb`
Expected: FAIL — `uninitialized constant AuditEvent`.

- [ ] **Step 4: Implement**

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :workspace, :project
  attribute :ip

  delegate :user, to: :session, allow_nil: true
end
```

```ruby
# app/controllers/application_controller.rb — add before the closing end
  before_action { Current.ip = request.remote_ip }
```

```ruby
# app/models/audit_event.rb
class AuditEvent < ApplicationRecord
  ACTIONS = %w[
    api_key.issued api_key.revoked api_key.rotated
    invitation.created invitation.accepted
    domain.created domain.verified domain.destroyed
    source.created source.updated
    webhook_endpoint.created webhook_endpoint.updated webhook_endpoint.destroyed
    suppression.created suppression.destroyed
    two_factor.enabled two_factor.disabled
    two_factor.recovery_codes_regenerated two_factor.recovery_code_redeemed
    workspace.two_factor_required workspace.two_factor_requirement_removed
    session.revoked session.bulk_revoked
  ].freeze

  belongs_to :workspace, optional: true
  belongs_to :user, optional: true
  belongs_to :subject, polymorphic: true, optional: true

  validates :action, inclusion: { in: ACTIONS }

  scope :reverse_chronologically, -> { order(created_at: :desc, id: :desc) }
  scope :preloaded, -> { includes(:user, :subject) }
  scope :indexed_by, ->(group) do
    case group
    when "api_keys" then where("action LIKE 'api_key.%'")
    when "members" then where("action LIKE 'invitation.%'")
    when "sending" then where("action LIKE 'domain.%' OR action LIKE 'source.%' OR action LIKE 'suppression.%' OR action LIKE 'webhook_endpoint.%'")
    when "security" then where("action LIKE 'two_factor.%' OR action LIKE 'session.%' OR action LIKE 'workspace.%'")
    else all
    end
  end
  scope :in_time_range, ->(range) do
    case range
    when "24h" then where(created_at: 24.hours.ago..)
    when "7d" then where(created_at: 7.days.ago..)
    when "30d" then where(created_at: 30.days.ago..)
    else all
    end
  end

  class << self
    def record(action, subject: nil, metadata: {}, workspace: Current.workspace, user: Current.user)
      create!(action: action, subject: subject, metadata: metadata, workspace: workspace, user: user, ip: Current.ip)
    end

    def prune
      where(created_at: ...180.days.ago).in_batches.delete_all
    end
  end
end
```

```ruby
# app/models/workspace.rb — add with the other has_many lines
  has_many :audit_events, dependent: :destroy
```

```ruby
# app/jobs/prune_retention_job.rb — add one line to perform
    AuditEvent.prune
```

- [ ] **Step 5: Run tests, full suite, rubocop, commit**

Run: `bin/rails test test/models/audit_event_test.rb && bin/rails test && bin/rubocop`

```bash
git add db/migrate db/schema.rb app/models app/controllers/application_controller.rb app/jobs/prune_retention_job.rb test/models/audit_event_test.rb
git commit -m "feat: AuditEvent — curated action allowlist, Current-sourced context, 180-day retention"
```

---

### Task 8: Audit instrumentation at every curated call site

**Files:**
- Modify: `app/models/api_key.rb`, `app/models/invitation.rb`, `app/models/domain.rb`, `app/models/user/two_factor.rb`, `app/controllers/workspaces/invitations_controller.rb`, `app/controllers/domains_controller.rb`, `app/controllers/sources_controller.rb`, `app/controllers/webhook_endpoints_controller.rb`, `app/controllers/suppressions_controller.rb`, `app/controllers/workspaces_controller.rb`, `app/controllers/sessions_controller.rb`, `app/controllers/other_sessions_controller.rb`
- Test: `test/models/audit_instrumentation_test.rb`, `test/controllers/audit_instrumentation_controller_test.rb`

Rich domain actions record inside the model method that performs them; bare CRUD records in the controller action, because there the action *is* the model lifecycle call. SNS-driven suppressions (system events) are deliberately NOT audited — only manual dashboard ones.

**Interfaces:**
- Consumes: `AuditEvent.record` (Task 7).
- Produces: audit rows for every action in `AuditEvent::ACTIONS`.

- [ ] **Step 1: Write the failing model-level test**

```ruby
# test/models/audit_instrumentation_test.rb
require "test_helper"

class AuditInstrumentationTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    Current.workspace = workspaces(:acme)
  end

  teardown do
    Current.reset
  end

  test "issuing, revoking and rotating an API key are audited" do
    api_key = ApiKey.issue(project: projects(:acme_default), scopes: %w[ send ])
    assert_audited "api_key.issued", subject: api_key

    api_key.revoke
    assert_audited "api_key.revoked", subject: api_key

    rotated = api_keys(:acme_full).rotate
    assert_audited "api_key.rotated", subject: api_keys(:acme_full)
    assert_audited "api_key.issued", subject: rotated
  end

  test "accepting an invitation is audited" do
    invitation = workspaces(:acme).invitations.create!(email: "new@example.com", role: "member")
    invitation.accept(user: users(:outsider))

    assert_audited "invitation.accepted", subject: invitation
  end

  test "a domain flipping to verified is audited" do
    domain = domains(:acme_pending)
    domain.ses_client.stub_responses(:get_email_identity, verified_for_sending_status: true, dkim_attributes: { tokens: %w[ a b c ] })

    domain.check

    assert_audited "domain.verified", subject: domain
  end

  test "2FA lifecycle is audited" do
    user = users(:jorge)
    user.prepare_two_factor
    codes = user.enable_two_factor(Totp.new(user.otp_secret).code)
    assert_audited "two_factor.enabled", subject: user

    user.regenerate_recovery_codes
    assert_audited "two_factor.recovery_codes_regenerated", subject: user

    user.redeem_recovery_code(codes.first)
    assert_audited "two_factor.recovery_code_redeemed", subject: user

    user.disable_two_factor
    assert_audited "two_factor.disabled", subject: user
  end

  private
    def assert_audited(action, subject:)
      assert AuditEvent.exists?(action: action, subject: subject), "expected an audit event #{action} for #{subject.class}##{subject.id}"
    end
end
```

Fixture names verified against `test/fixtures/`: `projects(:acme_default)`, `api_keys(:acme_full)`, `domains(:acme_pending)`. `Domain#ses_client` is memoized with an `attr_writer` and stubbable exactly as in `test/models/domain_test.rb`. `Domain#check` also stubs `get_email_identity` with `dkim_attributes` because the method reads both fields.

- [ ] **Step 2: Write the failing controller-level test**

```ruby
# test/controllers/audit_instrumentation_controller_test.rb
require "test_helper"

class AuditInstrumentationControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
  end

  test "manual suppression create and destroy are audited" do
    post suppressions_path, params: { suppression: { email: "audit-me@example.com" } }
    assert AuditEvent.exists?(action: "suppression.created")

    suppression = Suppression.find_by!(email: "audit-me@example.com")
    delete suppression_path(suppression)
    assert AuditEvent.exists?(action: "suppression.destroyed")
  end

  test "inviting a member is audited" do
    post workspace_invitations_path(workspaces(:acme)), params: { invitation: { email: "invitee@example.com", role: "member" } }
    assert AuditEvent.exists?(action: "invitation.created", workspace: workspaces(:acme))
  end

  test "toggling require_two_factor is audited in both directions" do
    patch workspace_path(workspaces(:acme)), params: { workspace: { require_two_factor: true } }
    assert AuditEvent.exists?(action: "workspace.two_factor_required", subject: workspaces(:acme))

    # pass the gate for the second toggle: the owner is now inside an enforcing workspace
    enable_two_factor_for users(:owner)

    patch workspace_path(workspaces(:acme)), params: { workspace: { require_two_factor: false } }
    assert AuditEvent.exists?(action: "workspace.two_factor_requirement_removed", subject: workspaces(:acme))
  end

  test "revoking sessions is audited" do
    other = users(:owner).sessions.create!(user_agent: "OtherBrowser", ip_address: "10.0.0.1")

    delete user_session_path(other)
    assert AuditEvent.exists?(action: "session.revoked")

    users(:owner).sessions.create!(user_agent: "ThirdBrowser", ip_address: "10.0.0.2")
    delete other_sessions_path
    assert AuditEvent.exists?(action: "session.bulk_revoked")
  end

  test "source and webhook endpoint changes are audited" do
    patch source_path(sources(:acme_production)), params: { source: { name: "Renamed" } }
    assert AuditEvent.exists?(action: "source.updated", subject: sources(:acme_production))

    delete webhook_endpoint_path(webhook_endpoints(:acme_all))
    assert AuditEvent.exists?(action: "webhook_endpoint.destroyed")
  end
end
```

Fixture names verified: `sources(:acme_production)`, `webhook_endpoints(:acme_all)`.

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/models/audit_instrumentation_test.rb test/controllers/audit_instrumentation_controller_test.rb`
Expected: FAIL — no audit rows written.

- [ ] **Step 4: Instrument the call sites**

Model methods (add exactly one `AuditEvent.record` line per site):

```ruby
# app/models/api_key.rb
#   in issue, inside the .tap block after the token ivar is set:
        AuditEvent.record("api_key.issued", subject: api_key, metadata: { prefix: api_key.prefix }, workspace: api_key.workspace)
#   in revoke, inside the `unless revoked?` branch after update!:
      AuditEvent.record("api_key.revoked", subject: self, metadata: { prefix: prefix }, workspace: workspace)
#   in rotate, inside the transaction before issue:
      AuditEvent.record("api_key.rotated", subject: self, metadata: { prefix: prefix }, workspace: workspace)
```

```ruby
# app/models/invitation.rb — in accept, inside the transaction after update!:
      AuditEvent.record("invitation.accepted", subject: self, metadata: { email: email, role: role }, workspace: workspace, user: user)
```

```ruby
# app/models/domain.rb — in check, record only on a fresh flip to verified.
# Capture the prior status first line of the method body:
    previously_verified = verified?
# then after the update! that sets the status:
    if verified? && !previously_verified
      AuditEvent.record("domain.verified", subject: self, metadata: { name: name }, workspace: workspace)
    end
```

```ruby
# app/models/user/two_factor.rb
#   enable_two_factor — inside the success branch, after update!:
      AuditEvent.record("two_factor.enabled", subject: self, user: self)
#   disable_two_factor — after update!:
    AuditEvent.record("two_factor.disabled", subject: self, user: self)
#   regenerate_recovery_codes — after update!:
    AuditEvent.record("two_factor.recovery_codes_regenerated", subject: self, user: self)
#   redeem_recovery_code — inside the success branch, after update!:
      AuditEvent.record("two_factor.recovery_code_redeemed", subject: self, user: self)
```

Controller actions (one line each, right after the successful state change):

```ruby
# workspaces/invitations_controller.rb#create — after deliver_later:
      AuditEvent.record("invitation.created", subject: @invitation, metadata: { email: @invitation.email, role: @invitation.role }, workspace: @workspace)

# domains_controller.rb#create — after @domain.save succeeds (before the provision branch):
        AuditEvent.record("domain.created", subject: @domain, metadata: { name: @domain.name })
# domains_controller.rb#destroy — capture then record:
    domain = Current.project.domains.find(params[:id])
    domain.decommission
    AuditEvent.record("domain.destroyed", metadata: { name: domain.name })

# sources_controller.rb#create — in the success branch:
      AuditEvent.record("source.created", subject: @source, metadata: { environment: @source.environment })
# sources_controller.rb#update — in the success branch:
      AuditEvent.record("source.updated", subject: @source, metadata: { environment: @source.environment })

# webhook_endpoints_controller.rb — success branches of create/update/destroy:
      AuditEvent.record("webhook_endpoint.created", subject: @webhook_endpoint, metadata: { url: @webhook_endpoint.url })
      AuditEvent.record("webhook_endpoint.updated", subject: @webhook_endpoint, metadata: { url: @webhook_endpoint.url })
    AuditEvent.record("webhook_endpoint.destroyed", metadata: { url: @webhook_endpoint.url })

# suppressions_controller.rb#create — after Suppression.record succeeds:
    suppression = Suppression.record(Current.project, suppression_params[:email], reason: "manual")
    AuditEvent.record("suppression.created", subject: suppression, metadata: { email: suppression.email })
# suppressions_controller.rb#destroy — capture then record:
    suppression = Current.project.suppressions.find(params[:id])
    suppression.destroy
    AuditEvent.record("suppression.destroyed", metadata: { email: suppression.email })

# workspaces_controller.rb#update — in the success branch, when the flag changed:
      if @workspace.saved_change_to_require_two_factor?
        action = @workspace.require_two_factor? ? "workspace.two_factor_required" : "workspace.two_factor_requirement_removed"
        AuditEvent.record(action, subject: @workspace, workspace: @workspace)
      end

# sessions_controller.rb#destroy — in the non-current branch, after destroy:
      AuditEvent.record("session.revoked", metadata: { device: session_record.device_summary })

# other_sessions_controller.rb#destroy — capture the count first:
    revoked = Current.user.sessions.where.not(id: Current.session.id).destroy_all
    AuditEvent.record("session.bulk_revoked", metadata: { count: revoked.size })
```

Caveat for the 2FA sites: `enable_two_factor` etc. run in model tests without `Current` set — `AuditEvent.record` already tolerates nil workspace/user, and we pass `user: self` explicitly so the actor is never lost.

- [ ] **Step 5: Run tests, full suite, rubocop, commit**

Run: `bin/rails test test/models/audit_instrumentation_test.rb test/controllers/audit_instrumentation_controller_test.rb && bin/rails test && bin/rubocop`

Existing tests that assert absolute DB counts may now also create audit rows — that's expected; fix any that assert on `AuditEvent` tables only if they break (none should).

```bash
git add app/models app/controllers test
git commit -m "feat: audit every curated sensitive action"
```

---

### Task 9: Audit log viewer

**Files:**
- Create: `app/controllers/audit_events_controller.rb`, `app/views/audit_events/index.html.erb`
- Modify: `app/models/workspace/roles.rb`, `config/routes.rb`, `app/views/layouts/_nav.html.erb`
- Test: `test/controllers/audit_events_controller_test.rb`, extend `test/models/workspace_test.rb` (capability matrix)

**Interfaces:**
- Consumes: `AuditEvent` scopes (Task 7), `authorize_capability!`.
- Produces: route `audit_events_path` (GET /audit_events); `view_audit_log` capability (owner only — the roles that hold `manage_members`).

- [ ] **Step 1: Write the failing tests**

```ruby
# test/controllers/audit_events_controller_test.rb
require "test_helper"

class AuditEventsControllerTest < ActionDispatch::IntegrationTest
  test "owner sees the workspace audit log" do
    sign_in_as users(:owner)
    AuditEvent.record("api_key.revoked", workspace: workspaces(:acme), user: users(:owner))

    get audit_events_path

    assert_response :success
    assert_match "api_key.revoked", response.body
  end

  test "events from other workspaces never appear" do
    sign_in_as users(:owner)
    AuditEvent.record("domain.created", workspace: workspaces(:globex), user: users(:outsider))

    get audit_events_path

    assert_response :success
    assert_no_match "domain.created", response.body
  end

  test "members without manage_members are forbidden" do
    sign_in_as users(:member)

    get audit_events_path

    assert_response :forbidden
  end

  test "filters narrow the list" do
    sign_in_as users(:owner)
    AuditEvent.record("api_key.revoked", workspace: workspaces(:acme))
    AuditEvent.record("two_factor.enabled", workspace: workspaces(:acme))

    get audit_events_path, params: { group: "security" }

    assert_response :success
    assert_match "two_factor.enabled", response.body
    assert_no_match "api_key.revoked", response.body
  end
end
```

Capability matrix addition (in `test/models/workspace_test.rb`, alongside the existing role tests):

```ruby
  test "only owners can view the audit log" do
    assert workspaces(:acme).capability?(users(:owner), :view_audit_log)
    %i[ member sender api_keys domains read_only ].each do |role|
      assert_not workspaces(:acme).capability?(users(role), :view_audit_log), "#{role} should not view audit log"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/audit_events_controller_test.rb test/models/workspace_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement**

```ruby
# app/models/workspace/roles.rb — owner line becomes:
    "owner"     => %w[ send manage_api_keys manage_domains manage_templates manage_webhooks manage_members view_audit_log ],
```

Route:

```ruby
resources :audit_events, only: :index
```

```ruby
# app/controllers/audit_events_controller.rb
class AuditEventsController < ApplicationController
  before_action -> { authorize_capability! :view_audit_log }

  def index
    @audit_events = Current.workspace.audit_events
      .indexed_by(params[:group])
      .in_time_range(params[:range])
      .preloaded
      .reverse_chronologically
      .limit(200)
  end
end
```

```erb
<%# app/views/audit_events/index.html.erb %>
<% content_for :title, "Audit log" %>

<h1>Audit log</h1>

<%= form_with url: audit_events_path, method: :get, data: { controller: "auto-submit" } do |form| %>
  <%= form.select :group, options_for_select(
        [ [ "All events", "" ], [ "API keys", "api_keys" ], [ "Members", "members" ],
          [ "Sending", "sending" ], [ "Security", "security" ] ], params[:group]),
      {}, class: "input input--select", data: { action: "auto-submit#submit" } %>
  <%= form.select :range, options_for_select(
        [ [ "All time", "" ], [ "Last 24 hours", "24h" ], [ "Last 7 days", "7d" ], [ "Last 30 days", "30d" ] ], params[:range]),
      {}, class: "input input--select", data: { action: "auto-submit#submit" } %>
<% end %>

<table>
  <thead>
    <tr><th>When</th><th>Who</th><th>Action</th><th>Details</th><th>IP</th></tr>
  </thead>
  <tbody>
    <% @audit_events.each do |event| %>
      <tr>
        <td><%= event.created_at.to_fs(:short) %></td>
        <td><%= event.user&.email_address || "system" %></td>
        <td><code><%= event.action %></code></td>
        <td><%= event.metadata.map { |key, value| "#{key}: #{value}" }.join(", ") %></td>
        <td><%= event.ip %></td>
      </tr>
    <% end %>
  </tbody>
</table>

<% if @audit_events.empty? %>
  <p>No audit events yet.</p>
<% end %>
```

(The `auto-submit` Stimulus controller already exists — `app/javascript/controllers/auto_submit_controller.js`; verify its action name matches (`auto-submit#submit`) and adjust if it differs.)

Nav — inside the existing capability-gated "Workspace" block from Task 5 (audit log is owner-only, `view_audit_log`):

```erb
  <% if Current.workspace&.capability?(Current.user, :view_audit_log) %>
    <%= link_to "Audit log", audit_events_path, class: "nav__link", aria: { current: current_page?(audit_events_path) ? "page" : nil } %>
  <% end %>
```

- [ ] **Step 4: Run tests, full suite, rubocop, commit**

Run: `bin/rails test test/controllers/audit_events_controller_test.rb test/models/workspace_test.rb && bin/rails test && bin/rubocop`

```bash
git add app/models/workspace/roles.rb app/controllers/audit_events_controller.rb app/views config/routes.rb test
git commit -m "feat: workspace audit log viewer behind view_audit_log capability"
```

---

### Task 10: Closing adversarial security review

**Files:** review findings drive their own fixes + regression tests; update `docs/plans/departures-execution-plan.md` phase status at the end.

- [ ] **Step 1: Run the review**

Use `superpowers:requesting-code-review` (multi-agent, adversarial) across the whole application with these explicit dimensions:

1. Authentication + the new 2FA/challenge flow (pending-cookie handling, replay, rate limits, enumeration).
2. Tenancy isolation — every dashboard controller scopes through `Current.user.workspaces` / `Current.workspace`; cross-tenant requests 404.
3. API auth and scope enforcement (`send` vs `read:activity`), rate limiting order relative to auth.
4. SNS signature verification (`lib/sns/message_verifier.rb`) — cert pinning, algorithm confusion.
5. Webhook endpoint SSRF protections and `Departures-Signature` HMAC.
6. Secrets: encrypted columns, one-time reveals, log hygiene (no secrets/codes in logs).
7. Security headers/CSP (including the email preview iframe CSP) and cookie flags.
8. `bin/ci` (brakeman, bundler-audit, importmap audit) — all green.

- [ ] **Step 2: Triage and fix**

For each CONFIRMED finding: write a failing regression test, fix, commit individually (`fix: <finding>` messages). Reject or document dismissed findings in the review notes.

- [ ] **Step 3: Phase close**

Run: `bin/ci`
Expected: fully green.

Update `docs/plans/departures-execution-plan.md`: add a Phase 8 section mirroring the other phases' status lines (detailed plan link + "complete" note). Commit:

```bash
git add docs/plans/departures-execution-plan.md
git commit -m "docs: phase 8 (security hardening) status"
```

---

## Verification (phase-level)

- 2FA: enrollment → challenge login → recovery-code login all work in the browser (`bin/dev`), QR renders offline (no external requests in the network tab), light + dark.
- Enforcement: a workspace with `require_two_factor` blocks an unenrolled member but not their other workspaces.
- Sessions: second browser session appears in the list; revoking it logs that browser out on next request.
- Audit: every action in `AuditEvent::ACTIONS` has at least one test asserting it is recorded; viewer 403s for non-owners; foreign-workspace events invisible.
- `rg "def \w+!" app lib` still finds only bang methods with non-bang counterparts; no raw color values in any new CSS; `bin/ci` green.

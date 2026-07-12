# departures-ruby Client Gem Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `departures-ruby` gem — a zero-runtime-dependency Ruby API client plus an ActionMailer delivery method for the Departures platform — in a new repository at `~/Sites/rails/departures-ruby`.

**Architecture:** `Departures::Client` speaks to `POST/GET /api/emails` over stdlib `Net::HTTP` with typed error mapping. `Departures::DeliveryMethod` decomposes a `Mail::Message` into the API's JSON payload and delegates to the client. A Railtie registers `:departures` as an ActionMailer delivery method when Rails is present.

**Tech Stack:** Ruby ≥ 3.1, stdlib only at runtime (`net/http`, `json`, `uri`). Dev-only: minitest, webmock, mail, rake, rubocop-rails-omakase.

**Spec:** `docs/superpowers/specs/2026-07-10-departures-ruby-gem-design.md` (in the departures platform repo).

## Global Constraints

- Zero runtime dependencies. Never `require "base64"` (not a default gem in Ruby 3.4) — Base64 via `[data].pack("m0")`.
- `required_ruby_version = ">= 3.1"`. No Rails version constraint; `lib/departures/railtie.rb` loads only when `Rails::Railtie` is defined.
- Gem name `departures-ruby`, top-level module `Departures`.
- Errors raise; no internal retries. Retry policy belongs to the caller's job layer.
- Style: rubocop-rails-omakase. Every task ends with `bundle exec rake test` and `bundle exec rubocop` green plus a commit.
- All commands below run from `~/Sites/rails/departures-ruby` unless stated otherwise.

---

### Task 1: Repository scaffold

**Files:**
- Create: `departures-ruby.gemspec`, `Gemfile`, `Rakefile`, `.rubocop.yml`, `.gitignore`, `LICENSE`, `lib/departures.rb`, `lib/departures/version.rb`, `test/test_helper.rb`, `test/departures/version_test.rb`

**Interfaces:**
- Produces: `Departures::VERSION` (String `"0.1.0"`), a runnable test harness (`bundle exec rake test`), rubocop config. Later tasks add `require_relative` lines to `lib/departures.rb`.

- [ ] **Step 1: Create the repo**

```bash
mkdir -p ~/Sites/rails/departures-ruby && cd ~/Sites/rails/departures-ruby && git init
```

- [ ] **Step 2: Write the scaffold files**

`lib/departures/version.rb`:

```ruby
module Departures
  VERSION = "0.1.0"
end
```

`lib/departures.rb`:

```ruby
require_relative "departures/version"

module Departures
end
```

`departures-ruby.gemspec`:

```ruby
require_relative "lib/departures/version"

Gem::Specification.new do |spec|
  spec.name = "departures-ruby"
  spec.version = Departures::VERSION
  spec.authors = [ "Jorge Alvarez" ]
  spec.summary = "Ruby client and ActionMailer delivery method for Departures"
  spec.description = "Send transactional email through a self-hosted Departures server: a plain API client plus an ActionMailer delivery method."
  spec.homepage = "https://github.com/jorgegorka/departures-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["lib/**/*.rb", "LICENSE", "README.md"]
  spec.require_paths = [ "lib" ]
  spec.metadata["rubygems_mfa_required"] = "true"
end
```

`Gemfile`:

```ruby
source "https://rubygems.org"

gemspec

group :development do
  gem "rake"
  gem "minitest", "~> 5.25"
  gem "webmock"
  gem "mail"
  gem "rubocop-rails-omakase", require: false
end
```

`Rakefile`:

```ruby
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.pattern = "test/**/*_test.rb"
end

task default: :test
```

`.rubocop.yml`:

```yaml
inherit_gem:
  rubocop-rails-omakase: rubocop.yml
```

`.gitignore`:

```
/Gemfile.lock
/pkg/
/.bundle/
```

`LICENSE`: standard MIT license text with `Copyright (c) 2026 Jorge Alvarez`.

`test/test_helper.rb`:

```ruby
require "minitest/autorun"
require "webmock/minitest"
require "departures"
```

- [ ] **Step 3: Write a smoke test proving the harness runs**

`test/departures/version_test.rb`:

```ruby
require "test_helper"

class Departures::VersionTest < Minitest::Test
  def test_version_is_set
    assert_match(/\A\d+\.\d+\.\d+\z/, Departures::VERSION)
  end
end
```

- [ ] **Step 4: Install and verify green**

Run: `bundle install && bundle exec rake test && bundle exec rubocop`
Expected: 1 test, 0 failures; no rubocop offenses.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "chore: scaffold departures-ruby gem"
```

---

### Task 2: Typed errors

**Files:**
- Create: `lib/departures/errors.rb`
- Modify: `lib/departures.rb` (add `require_relative "departures/errors"` after the version require)
- Test: `test/departures/errors_test.rb`

**Interfaces:**
- Produces: `Departures::Error < StandardError`; `Departures::ConnectionError < Error`; `Departures::ApiError < Error` with `initialize(status:, errors:)`, readers `status` (Integer) and `errors` (Array of Strings), and class method `ApiError.for(status, errors)` returning the right subclass instance; subclasses `AuthenticationError` (401/403), `RateLimitedError` (429), `SuppressedRecipientsError` (422 whose messages match `/suppress/i`).

- [ ] **Step 1: Write the failing tests**

`test/departures/errors_test.rb`:

```ruby
require "test_helper"

class Departures::ErrorsTest < Minitest::Test
  def test_for_maps_401_and_403_to_authentication_error
    assert_instance_of Departures::AuthenticationError, Departures::ApiError.for(401, [])
    assert_instance_of Departures::AuthenticationError, Departures::ApiError.for(403, [])
  end

  def test_for_maps_429_to_rate_limited_error
    assert_instance_of Departures::RateLimitedError, Departures::ApiError.for(429, [])
  end

  def test_for_maps_suppressed_422_to_suppressed_recipients_error
    error = Departures::ApiError.for(422, [ "Recipients are suppressed: a@b.com" ])
    assert_instance_of Departures::SuppressedRecipientsError, error
  end

  def test_for_maps_other_422_to_plain_api_error
    error = Departures::ApiError.for(422, [ "From is invalid" ])
    assert_instance_of Departures::ApiError, error
    refute_instance_of Departures::SuppressedRecipientsError, error
  end

  def test_for_maps_500_to_plain_api_error
    assert_instance_of Departures::ApiError, Departures::ApiError.for(500, [])
  end

  def test_carries_status_and_errors_and_builds_message
    error = Departures::ApiError.for(422, [ "From is invalid", "Subject is blank" ])
    assert_equal 422, error.status
    assert_equal [ "From is invalid", "Subject is blank" ], error.errors
    assert_equal "Departures API error (422): From is invalid; Subject is blank", error.message
  end

  def test_hierarchy
    assert_operator Departures::ConnectionError, :<, Departures::Error
    assert_operator Departures::ApiError, :<, Departures::Error
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rake test`
Expected: FAIL with `NameError: uninitialized constant Departures::ApiError`

- [ ] **Step 3: Implement**

`lib/departures/errors.rb`:

```ruby
module Departures
  class Error < StandardError; end

  class ConnectionError < Error; end

  class ApiError < Error
    attr_reader :status, :errors

    def self.for(status, errors)
      klass = case status
      when 401, 403
        AuthenticationError
      when 429
        RateLimitedError
      when 422
        errors.any? { |message| message.match?(/suppress/i) } ? SuppressedRecipientsError : ApiError
      else
        ApiError
      end

      klass.new(status: status, errors: errors)
    end

    def initialize(status:, errors:)
      @status = status
      @errors = errors
      super("Departures API error (#{status}): #{errors.join("; ")}")
    end
  end

  class AuthenticationError < ApiError; end
  class RateLimitedError < ApiError; end
  class SuppressedRecipientsError < ApiError; end
end
```

And in `lib/departures.rb`:

```ruby
require_relative "departures/version"
require_relative "departures/errors"

module Departures
end
```

- [ ] **Step 4: Verify green**

Run: `bundle exec rake test && bundle exec rubocop`
Expected: all tests pass, no offenses.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: typed error hierarchy with status-based mapping"
```

---

### Task 3: Departures::Client

**Files:**
- Create: `lib/departures/client.rb`
- Modify: `lib/departures.rb` (add `require_relative "departures/client"`)
- Test: `test/departures/client_test.rb`

**Interfaces:**
- Consumes: `Departures::ApiError.for(status, errors)`, `Departures::ConnectionError` (Task 2).
- Produces: `Departures::Client#initialize(api_key:, base_url:, open_timeout: 5, read_timeout: 15)`; `#send_email(from:, to:, subject: nil, html: nil, text: nil, cc: nil, bcc: nil, headers: nil, tags: nil, attachments: nil, template_id: nil, variables: nil, environment: nil, idempotency_key: nil)` → parsed response Hash (e.g. `{ "id" => "em_..." }`); `#list_emails` → Array from the response's `data` key.

- [ ] **Step 1: Write the failing tests**

`test/departures/client_test.rb`:

```ruby
require "test_helper"

class Departures::ClientTest < Minitest::Test
  def setup
    @client = Departures::Client.new(api_key: "dp_test123", base_url: "https://departures.example.com")
  end

  def test_send_email_posts_json_with_bearer_auth_and_returns_parsed_body
    stub = stub_request(:post, "https://departures.example.com/api/emails")
      .with(
        headers: { "Authorization" => "Bearer dp_test123", "Content-Type" => "application/json" },
        body: { from: "a@b.com", to: [ "c@d.com" ], subject: "Hi", text: "Hello" }.to_json
      )
      .to_return(status: 202, body: { id: "em_abc" }.to_json)

    response = @client.send_email(from: "a@b.com", to: [ "c@d.com" ], subject: "Hi", text: "Hello")

    assert_requested(stub)
    assert_equal({ "id" => "em_abc" }, response)
  end

  def test_send_email_omits_nil_params_from_the_body
    stub_request(:post, "https://departures.example.com/api/emails")
      .with { |request| !JSON.parse(request.body).key?("cc") && !JSON.parse(request.body).key?("html") }
      .to_return(status: 202, body: { id: "em_abc" }.to_json)

    @client.send_email(from: "a@b.com", to: [ "c@d.com" ], subject: "Hi", text: "Hello")
  end

  def test_send_email_sends_idempotency_key_header_when_given
    stub_request(:post, "https://departures.example.com/api/emails")
      .with(headers: { "Idempotency-Key" => "key-123" })
      .to_return(status: 202, body: { id: "em_abc" }.to_json)

    @client.send_email(from: "a@b.com", to: [ "c@d.com" ], subject: "Hi", text: "x", idempotency_key: "key-123")
  end

  def test_send_email_never_sends_idempotency_key_header_by_default
    stub_request(:post, "https://departures.example.com/api/emails")
      .with { |request| !request.headers.key?("Idempotency-Key") }
      .to_return(status: 202, body: { id: "em_abc" }.to_json)

    @client.send_email(from: "a@b.com", to: [ "c@d.com" ], subject: "Hi", text: "x")
  end

  def test_401_raises_authentication_error
    stub_request(:post, "https://departures.example.com/api/emails")
      .to_return(status: 401, body: { error: "Invalid API key" }.to_json)

    error = assert_raises(Departures::AuthenticationError) { send_minimal }
    assert_equal 401, error.status
    assert_equal [ "Invalid API key" ], error.errors
  end

  def test_429_raises_rate_limited_error
    stub_request(:post, "https://departures.example.com/api/emails").to_return(status: 429, body: "")

    assert_raises(Departures::RateLimitedError) { send_minimal }
  end

  def test_suppressed_422_raises_suppressed_recipients_error
    stub_request(:post, "https://departures.example.com/api/emails")
      .to_return(status: 422, body: { errors: [ "Recipients are suppressed: c@d.com" ] }.to_json)

    assert_raises(Departures::SuppressedRecipientsError) { send_minimal }
  end

  def test_validation_422_raises_api_error_with_messages
    stub_request(:post, "https://departures.example.com/api/emails")
      .to_return(status: 422, body: { errors: [ "From is invalid" ] }.to_json)

    error = assert_raises(Departures::ApiError) { send_minimal }
    assert_equal [ "From is invalid" ], error.errors
  end

  def test_unparseable_error_body_yields_empty_errors
    stub_request(:post, "https://departures.example.com/api/emails")
      .to_return(status: 500, body: "<html>boom</html>")

    error = assert_raises(Departures::ApiError) { send_minimal }
    assert_equal [], error.errors
  end

  def test_timeout_raises_connection_error
    stub_request(:post, "https://departures.example.com/api/emails").to_timeout

    assert_raises(Departures::ConnectionError) { send_minimal }
  end

  def test_refused_connection_raises_connection_error
    stub_request(:post, "https://departures.example.com/api/emails").to_raise(Errno::ECONNREFUSED)

    assert_raises(Departures::ConnectionError) { send_minimal }
  end

  def test_list_emails_returns_data_array
    stub_request(:get, "https://departures.example.com/api/emails")
      .with(headers: { "Authorization" => "Bearer dp_test123" })
      .to_return(status: 200, body: { data: [ { id: "em_abc", status: "sent" } ] }.to_json)

    assert_equal [ { "id" => "em_abc", "status" => "sent" } ], @client.list_emails
  end

  private
    def send_minimal
      @client.send_email(from: "a@b.com", to: [ "c@d.com" ], subject: "Hi", text: "x")
    end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rake test`
Expected: FAIL with `NameError: uninitialized constant Departures::Client`

- [ ] **Step 3: Implement**

`lib/departures/client.rb`:

```ruby
require "net/http"
require "json"
require "uri"

module Departures
  class Client
    NETWORK_ERRORS = [
      Timeout::Error, SocketError, EOFError, IOError,
      Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
      OpenSSL::SSL::SSLError
    ].freeze

    def initialize(api_key:, base_url:, open_timeout: 5, read_timeout: 15)
      @api_key = api_key
      @base_uri = URI(base_url)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def send_email(from:, to:, subject: nil, html: nil, text: nil, cc: nil, bcc: nil,
                   headers: nil, tags: nil, attachments: nil, template_id: nil,
                   variables: nil, environment: nil, idempotency_key: nil)
      body = {
        from: from, to: to, subject: subject, html: html, text: text, cc: cc, bcc: bcc,
        headers: headers, tags: tags, attachments: attachments,
        template_id: template_id, variables: variables, environment: environment
      }.compact

      extra_headers = idempotency_key ? { "Idempotency-Key" => idempotency_key } : {}
      post("/api/emails", body, extra_headers)
    end

    def list_emails
      get("/api/emails").fetch("data")
    end

    private
      def post(path, body, extra_headers = {})
        request = Net::HTTP::Post.new(path, request_headers.merge(extra_headers))
        request.body = body.to_json
        handle(perform(request))
      end

      def get(path)
        request = Net::HTTP::Get.new(path, request_headers)
        handle(perform(request))
      end

      def request_headers
        { "Authorization" => "Bearer #{@api_key}", "Content-Type" => "application/json" }
      end

      def perform(request)
        http = Net::HTTP.new(@base_uri.host, @base_uri.port)
        http.use_ssl = @base_uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        http.request(request)
      rescue *NETWORK_ERRORS => error
        raise ConnectionError, "#{error.class}: #{error.message}"
      end

      def handle(response)
        status = response.code.to_i

        if (200..299).cover?(status)
          JSON.parse(response.body)
        else
          raise ApiError.for(status, error_messages(response.body))
        end
      end

      def error_messages(body)
        parsed = JSON.parse(body.to_s)
        Array(parsed["errors"] || parsed["error"]).map(&:to_s)
      rescue JSON::ParserError
        []
      end
  end
end
```

And in `lib/departures.rb` add `require_relative "departures/client"` after the errors require.

- [ ] **Step 4: Verify green**

Run: `bundle exec rake test && bundle exec rubocop`
Expected: all tests pass, no offenses.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: Net::HTTP API client with typed error mapping"
```

---

### Task 4: Departures::DeliveryMethod

**Files:**
- Create: `lib/departures/delivery_method.rb`
- Modify: `lib/departures.rb` (add `require_relative "departures/delivery_method"`)
- Test: `test/departures/delivery_method_test.rb`

**Interfaces:**
- Consumes: `Departures::Client#send_email` (Task 3).
- Produces: `Departures::DeliveryMethod#initialize(settings)` — Hash with required `:api_key`, `:base_url`; optional `:environment`, `:open_timeout`, `:read_timeout`; raises `ArgumentError` when a required key is missing. `#deliver!(mail)` — POSTs the mapped payload, writes the returned id onto the mail as `X-Departures-Id`, returns the response Hash. Exposes `attr_reader :settings` (ActionMailer convention).

- [ ] **Step 1: Write the failing tests**

`test/departures/delivery_method_test.rb`:

```ruby
require "test_helper"
require "mail"

class Departures::DeliveryMethodTest < Minitest::Test
  def setup
    @method = Departures::DeliveryMethod.new(
      api_key: "dp_test123", base_url: "https://departures.example.com", environment: "production"
    )
  end

  def test_requires_api_key_and_base_url_at_boot
    assert_raises(ArgumentError) { Departures::DeliveryMethod.new(base_url: "https://x.com") }
    assert_raises(ArgumentError) { Departures::DeliveryMethod.new(api_key: "dp_x") }
  end

  def test_multipart_mail_maps_html_text_recipients_and_environment
    stub = stub_request(:post, "https://departures.example.com/api/emails")
      .with { |request| @body = JSON.parse(request.body) }
      .to_return(status: 202, body: { id: "em_abc" }.to_json)

    @method.deliver!(multipart_mail)

    assert_requested(stub)
    assert_equal "Sender <sender@example.com>", @body["from"]
    assert_equal [ "Ann <ann@example.com>", "bob@example.com" ], @body["to"]
    assert_equal [ "cc@example.com" ], @body["cc"]
    assert_equal [ "bcc@example.com" ], @body["bcc"]
    assert_equal "Welcome", @body["subject"]
    assert_equal "<h1>Hi</h1>", @body["html"]
    assert_equal "Hi", @body["text"]
    assert_equal "production", @body["environment"]
  end

  def test_text_only_mail_sends_text_and_omits_html
    stub_request(:post, "https://departures.example.com/api/emails")
      .with { |request| @body = JSON.parse(request.body) }
      .to_return(status: 202, body: { id: "em_abc" }.to_json)

    @method.deliver!(simple_mail(body: "plain hello", content_type: "text/plain; charset=UTF-8"))

    assert_equal "plain hello", @body["text"]
    refute @body.key?("html")
  end

  def test_html_only_mail_sends_html_and_omits_text
    stub_request(:post, "https://departures.example.com/api/emails")
      .with { |request| @body = JSON.parse(request.body) }
      .to_return(status: 202, body: { id: "em_abc" }.to_json)

    @method.deliver!(simple_mail(body: "<p>hi</p>", content_type: "text/html; charset=UTF-8"))

    assert_equal "<p>hi</p>", @body["html"]
    refute @body.key?("text")
  end

  def test_attachments_are_base64_encoded
    stub_request(:post, "https://departures.example.com/api/emails")
      .with { |request| @body = JSON.parse(request.body) }
      .to_return(status: 202, body: { id: "em_abc" }.to_json)

    mail = multipart_mail
    mail.add_file(filename: "report.pdf", content: "PDFDATA")
    @method.deliver!(mail)

    assert_equal 1, @body.fetch("attachments").size
    attachment = @body.fetch("attachments").first
    assert_equal "report.pdf", attachment["filename"]
    assert_equal "application/pdf", attachment["content_type"]
    assert_equal "PDFDATA", attachment["content"].unpack1("m0")
  end

  def test_custom_x_headers_pass_through_excluding_x_departures_id
    stub_request(:post, "https://departures.example.com/api/emails")
      .with { |request| @body = JSON.parse(request.body) }
      .to_return(status: 202, body: { id: "em_abc" }.to_json)

    mail = multipart_mail
    mail.header["X-Campaign"] = "onboarding"
    mail.header["X-Departures-Id"] = "should-be-dropped"
    @method.deliver!(mail)

    assert_equal({ "X-Campaign" => "onboarding" }, @body["headers"])
  end

  def test_deliver_writes_returned_id_back_onto_the_mail
    stub_request(:post, "https://departures.example.com/api/emails")
      .to_return(status: 202, body: { id: "em_abc" }.to_json)

    mail = multipart_mail
    @method.deliver!(mail)

    assert_equal "em_abc", mail.header["X-Departures-Id"].value
  end

  def test_api_errors_propagate
    stub_request(:post, "https://departures.example.com/api/emails")
      .to_return(status: 422, body: { errors: [ "Recipients are suppressed: ann@example.com" ] }.to_json)

    assert_raises(Departures::SuppressedRecipientsError) { @method.deliver!(multipart_mail) }
  end

  private
    def multipart_mail
      Mail.new do
        from "Sender <sender@example.com>"
        to [ "Ann <ann@example.com>", "bob@example.com" ]
        cc "cc@example.com"
        bcc "bcc@example.com"
        subject "Welcome"

        text_part { body "Hi" }
        html_part do
          content_type "text/html; charset=UTF-8"
          body "<h1>Hi</h1>"
        end
      end
    end

    def simple_mail(body:, content_type:)
      mail = Mail.new(from: "sender@example.com", to: "ann@example.com", subject: "Welcome", body: body)
      mail.content_type = content_type
      mail
    end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rake test`
Expected: FAIL with `NameError: uninitialized constant Departures::DeliveryMethod`

- [ ] **Step 3: Implement**

`lib/departures/delivery_method.rb`:

```ruby
module Departures
  class DeliveryMethod
    ID_HEADER = "X-Departures-Id"

    attr_reader :settings

    def initialize(settings)
      @settings = settings

      if settings[:api_key].nil? || settings[:base_url].nil?
        raise ArgumentError, "departures_settings requires :api_key and :base_url"
      end
    end

    def deliver!(mail)
      response = client.send_email(**payload_for(mail))
      mail.header[ID_HEADER] = response.fetch("id")
      response
    end

    private
      def client
        @client ||= Client.new(
          api_key: settings[:api_key],
          base_url: settings[:base_url],
          open_timeout: settings.fetch(:open_timeout, 5),
          read_timeout: settings.fetch(:read_timeout, 15)
        )
      end

      def payload_for(mail)
        {
          from: mail[:from].formatted.first,
          to: mail[:to].formatted,
          cc: mail[:cc]&.formatted,
          bcc: mail[:bcc]&.formatted,
          subject: mail.subject,
          html: html_body(mail),
          text: text_body(mail),
          attachments: attachments_for(mail),
          headers: custom_headers(mail),
          environment: settings[:environment]
        }.compact
      end

      def html_body(mail)
        if mail.multipart?
          mail.html_part&.decoded
        elsif mail.mime_type == "text/html"
          mail.body.decoded
        end
      end

      def text_body(mail)
        if mail.multipart?
          mail.text_part&.decoded
        elsif mail.mime_type == "text/plain"
          mail.body.decoded
        end
      end

      def attachments_for(mail)
        attachments = mail.attachments.map do |attachment|
          {
            filename: attachment.filename,
            content_type: attachment.mime_type,
            content: [ attachment.body.decoded ].pack("m0")
          }
        end

        attachments.empty? ? nil : attachments
      end

      def custom_headers(mail)
        headers = mail.header_fields
          .select { |field| field.name.start_with?("X-") && field.name != ID_HEADER }
          .to_h { |field| [ field.name, field.value ] }

        headers.empty? ? nil : headers
      end
  end
end
```

And in `lib/departures.rb` add `require_relative "departures/delivery_method"` after the client require.

- [ ] **Step 4: Verify green**

Run: `bundle exec rake test && bundle exec rubocop`
Expected: all tests pass, no offenses.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: ActionMailer delivery method mapping Mail::Message to the API payload"
```

---

### Task 5: Railtie, conditional loading, README

**Files:**
- Create: `lib/departures/railtie.rb`, `README.md`
- Modify: `lib/departures.rb` (conditional railtie require)
- Test: `test/departures/departures_test.rb`

**Interfaces:**
- Consumes: `Departures::DeliveryMethod` (Task 4).
- Produces: `Departures::Railtie` registering `add_delivery_method :departures, Departures::DeliveryMethod` on `:action_mailer` load. `lib/departures.rb` in final form.

- [ ] **Step 1: Write the failing test (railtie must not load outside Rails)**

`test/departures/departures_test.rb`:

```ruby
require "test_helper"

class Departures::DeparturesTest < Minitest::Test
  def test_railtie_is_not_loaded_outside_rails
    refute defined?(Departures::Railtie), "Railtie must only load when Rails::Railtie is defined"
  end

  def test_public_constants_are_loaded
    assert defined?(Departures::Client)
    assert defined?(Departures::DeliveryMethod)
    assert defined?(Departures::ApiError)
  end
end
```

- [ ] **Step 2: Run to verify current state**

Run: `bundle exec rake test`
Expected: PASS already (railtie file doesn't exist yet) — this test pins the conditional-load behavior before the railtie is added.

- [ ] **Step 3: Implement the railtie and final lib wiring**

`lib/departures/railtie.rb`:

```ruby
module Departures
  class Railtie < Rails::Railtie
    initializer "departures.add_delivery_method" do
      ActiveSupport.on_load(:action_mailer) do
        add_delivery_method :departures, Departures::DeliveryMethod
      end
    end
  end
end
```

`lib/departures.rb` (final form):

```ruby
require_relative "departures/version"
require_relative "departures/errors"
require_relative "departures/client"
require_relative "departures/delivery_method"
require_relative "departures/railtie" if defined?(Rails::Railtie)

module Departures
end
```

- [ ] **Step 4: Write the README**

`README.md` with: what the gem is (one paragraph), install (`gem "departures-ruby"`), Rails configuration block exactly as in the spec:

```ruby
config.action_mailer.delivery_method = :departures
config.action_mailer.departures_settings = {
  api_key: Rails.application.credentials.dig(:departures, :api_key),
  base_url: "https://departures.example.com",
  environment: "production" # optional; server default otherwise
}
```

plain-client usage (`Departures::Client.new(api_key:, base_url:).send_email(from:, to:, subject:, html:, text:, idempotency_key: nil)` and `list_emails`), the error class table (class → trigger), a note that `deliver!` never retries (pair with ActiveJob `retry_on`), and the `X-Departures-Id` back-reference behavior.

- [ ] **Step 5: Verify green**

Run: `bundle exec rake test && bundle exec rubocop`
Expected: all tests pass (railtie test still passes — Rails is not defined in the suite), no offenses.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: Railtie registration, conditional loading, README"
```

---

### Task 6: CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `bundle exec rake test`, `bundle exec rubocop` (Tasks 1–5).

- [ ] **Step 1: Write the workflow**

`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [ main ]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        ruby: [ "3.1", "3.2", "3.3", "3.4" ]
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: ${{ matrix.ruby }}
          bundler-cache: true
      - run: bundle exec rubocop
      - run: bundle exec rake test
```

- [ ] **Step 2: Verify locally one more time**

Run: `bundle exec rake test && bundle exec rubocop`
Expected: green.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "ci: test and lint matrix on Ruby 3.1-3.4"
```

---

### Task 7: Manual smoke against a local Departures server (phase close)

**Files:**
- Create: `script/smoke.rb` (in the gem repo, git-ignored or committed — committed is fine, it documents usage)

**Interfaces:**
- Consumes: the whole gem; a running Departures server (`bin/dev` in `~/Sites/rails/departures`) with a project, source, and API key.

- [ ] **Step 1: Prepare the server**

In `~/Sites/rails/departures`: run `bin/dev`. In the dashboard, use (or create) a project with a configured source and issue an API key with the `send` scope; copy the plaintext `dp_...` token.

- [ ] **Step 2: Write the smoke script**

`script/smoke.rb`:

```ruby
# Usage: DEPARTURES_API_KEY=dp_... DEPARTURES_URL=http://localhost:3000 ruby script/smoke.rb
require_relative "../lib/departures"
require "mail"

method = Departures::DeliveryMethod.new(
  api_key: ENV.fetch("DEPARTURES_API_KEY"),
  base_url: ENV.fetch("DEPARTURES_URL", "http://localhost:3000")
)

mail = Mail.new do
  from "Smoke Test <smoke@example.com>"
  to "recipient@example.com"
  subject "departures-ruby smoke test"

  text_part { body "It works." }
  html_part do
    content_type "text/html; charset=UTF-8"
    body "<p>It works.</p>"
  end
end

response = method.deliver!(mail)
puts "Accepted: #{response.inspect}"
puts "X-Departures-Id: #{mail.header['X-Departures-Id'].value}"
```

Run: `bundle exec ruby script/smoke.rb` with the env vars set.
Expected: `Accepted: {"id" => "..."}` and the id echoed from the mail header.

Note: the local server's SES client will attempt a real send unless the source's credentials are sandbox/stub — a 422/failed delivery status afterwards is fine; the smoke verifies the gem→API contract (202 accepted, payload valid), not SES delivery.

- [ ] **Step 3: Verify in the dashboard**

Open the project's activity feed; confirm the email row appeared with the same public id.

- [ ] **Step 4: Verify the Railtie in a Rails host**

In any scratch Rails app (or an existing local app): add `gem "departures-ruby", path: "~/Sites/rails/departures-ruby"` to its Gemfile, set the `config.action_mailer.departures_settings` block from the README, and from `rails console` run a mailer `.deliver_now`. Expected: 202-accepted send through the delivery method registered by the Railtie.

- [ ] **Step 5: Commit and close the phase**

```bash
git add -A && git commit -m "chore: smoke script against a local Departures server"
```

Then in `~/Sites/rails/departures`, update `docs/plans/departures-execution-plan.md` with a Phase 7 entry marked complete and commit as `docs: phase 7 (departures-ruby gem) status`.

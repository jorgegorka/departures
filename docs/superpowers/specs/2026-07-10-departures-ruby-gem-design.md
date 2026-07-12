# departures-ruby — Client Gem Design (Phase 7)

**Status:** Approved design, pending implementation plan.
**Repo:** new, separate repository at `~/Sites/rails/departures-ruby`.
**Gem name:** `departures-ruby`. Top-level module: `Departures`.

## Purpose

The deferred client-integration piece of the Departures platform: a Ruby gem that
lets any Ruby app send mail through a Departures server, and gives Rails apps a
one-config-line ActionMailer delivery method (the Rails equivalent of larasend's
Laravel mail driver).

## Scope

In: plain API client, ActionMailer delivery method, Railtie, typed errors.
Out (deliberately, YAGNI): webhook signature verification helper, auto-generated
idempotency keys, tags/templates via mailer headers, internal retries, raw-MIME
passthrough.

## Constraints

- **Zero runtime dependencies.** stdlib `net/http` and `json` only. Base64
  encoding via `Array#pack("m0")` — the `base64` gem is no longer a default gem
  in Ruby 3.4 and must not be required. The
  `mail` gem is provided by the host app's ActionMailer; the gem never declares it
  at runtime.
- Ruby ≥ 3.1. No Rails version constraint — the Railtie loads only when
  `Rails::Railtie` is defined.
- Style: rubocop-rails-omakase, same as the platform. Minitest.

## Architecture

One file per component under `lib/departures/`:

```
lib/departures.rb              # requires + Departures.const setup
lib/departures/version.rb
lib/departures/errors.rb
lib/departures/client.rb
lib/departures/delivery_method.rb
lib/departures/railtie.rb      # required only if Rails::Railtie is defined
```

### Departures::Client

Plain API client, usable without Rails.

- `initialize(api_key:, base_url:, open_timeout: 5, read_timeout: 15)`
- `send_email(from:, to:, subject: nil, html: nil, text: nil, cc: nil, bcc: nil,
  headers: nil, tags: nil, attachments: nil, template_id: nil, variables: nil,
  environment: nil, idempotency_key: nil)` → POST `/api/emails`, returns the
  parsed response hash (`{ "id" => "..." }`). `idempotency_key` is sent as the
  `Idempotency-Key` request header — pass-through only, never auto-generated.
  Nil params are omitted from the JSON body.
- `list_emails` → GET `/api/emails`, returns the parsed `data` array.
- HTTP: `Net::HTTP` with TLS, `Authorization: Bearer <api_key>`,
  `Content-Type: application/json`.

### Departures::DeliveryMethod

ActionMailer transport.

- `initialize(settings)` — validates `api_key` and `base_url` are present,
  raising `ArgumentError` at boot rather than at send time. Accepts optional
  `environment`, `open_timeout`, `read_timeout`; builds a memoized `Client`.
- `deliver!(mail)` — maps the `Mail::Message` to the API payload (see Mapping),
  calls `client.send_email`, writes the returned public id back onto the mail
  object as the `X-Departures-Id` header so callers and mailer observers can
  correlate the message with the platform record.

### Departures::Railtie

```ruby
ActiveSupport.on_load(:action_mailer) do
  add_delivery_method :departures, Departures::DeliveryMethod
end
```

### Errors (`Departures::Errors`)

- `Departures::Error` — base.
- `Departures::ConnectionError` — wraps socket/timeout/SSL failures.
- `Departures::ApiError` — non-2xx; carries `status` (Integer) and `errors`
  (Array of message strings parsed from the response body, empty if unparseable).
  Subclasses chosen by response:
  - `Departures::AuthenticationError` — 401 / 403.
  - `Departures::RateLimitedError` — 429.
  - `Departures::SuppressedRecipientsError` — 422 whose error messages mention
    suppressed recipients.

`deliver!` raises; there are no internal retries. Retry policy belongs to the
caller's job layer (`deliver_later` + ActiveJob `retry_on`), which can
discriminate by error class.

## Message mapping (`deliver!`)

| Mail::Message | API payload |
|---|---|
| `mail[:from].formatted.first` | `from` (display name preserved) |
| `mail[:to]/[:cc]/[:bcc].formatted` | `to` / `cc` / `bcc` arrays |
| `mail.subject` | `subject` |
| `html_part.decoded` or single-part `text/html` body | `html` |
| `text_part.decoded` or single-part `text/plain` body | `text` |
| `mail.attachments` | `attachments: [{ filename, content_type, content (Base64) }]` |
| user-set `X-*` headers, excluding `X-Departures-Id` | `headers` hash |

Tags, templates, and variables are not reachable from the mailer flow in v1 —
plain-client-only features.

## Configuration (Rails)

```ruby
config.action_mailer.delivery_method = :departures
config.action_mailer.departures_settings = {
  api_key: Rails.application.credentials.dig(:departures, :api_key),
  base_url: "https://departures.example.com",
  environment: "production" # optional; server default otherwise
}
```

Non-Rails: `Departures::Client.new(api_key:, base_url:).send_email(...)`.

## Testing

- Minitest. Dev-only dependencies: `webmock` (client HTTP behavior: request
  shape, auth header, idempotency header, error mapping per status, timeout →
  `ConnectionError`), `mail` (delivery-method tests build real `Mail::Message`
  objects — multipart, single-part html-only and text-only, attachments,
  display names, custom headers — and assert the produced payload).
- Boot-time settings validation tested directly (`ArgumentError` on missing
  `api_key` / `base_url`).
- CI: GitHub Actions matrix on Ruby 3.1, 3.2, 3.3, 3.4; rubocop + tests.

## Phase-close verification

Manual smoke against a locally running Departures server: a scratch script sends
through the delivery method with a real API key; confirm the email is accepted
(202), appears in the dashboard activity feed, and carries the `X-Departures-Id`
back-reference.

# Departures

Departures is a self-hosted transactional email platform built on Ruby on Rails. It acts as a control plane for Amazon SES: your applications send mail through a simple HTTP API, and Departures handles delivery through SES, tracks the full delivery lifecycle (deliveries, bounces, complaints, opens, clicks), maintains suppression lists, relays events to your own webhooks, and gives you an activity dashboard to inspect everything.

You run it yourself, on your own infrastructure, against your own AWS account. No per-email pricing, no third-party data processor — just SES rates and a single Rails app.

> **Status:** Feature-complete through production readiness (phases 0–9) plus in-app documentation.
> See `docs/plans/departures-execution-plan.md` for the build history.

## How it works

1. Your app makes a `POST /api/emails` request with a bearer API key (or uses a drop-in Action Mailer delivery method, planned as a companion gem).
2. Departures validates the request, checks guardrails (verified sending domain, suppression list, SES quota, complaint-rate circuit breaker), builds the full MIME message, persists it, and queues delivery through SES v2 raw send.
3. SES delivery events flow back via SNS to a per-source webhook endpoint. Departures verifies the SNS signature, records each event, advances the email's status, creates suppressions where appropriate, updates the dashboard in real time, and fans events out to your webhook endpoints.

## Documentation

Departures documents itself: every instance serves its own docs at **`/docs`** — publicly, versioned
with the code it describes. Guides for every dashboard feature, the full API reference, webhook
signature verification, and self-hosting runbooks (deployment, monitoring, backup & restore).

The official Ruby client is [`departures-ruby`](https://github.com/jorgegorka/departures-ruby): a
drop-in Action Mailer delivery method plus a plain HTTP client.

## Features

### Sending API

- `POST /api/emails` — to/cc/bcc, subject or template, HTML and/or text bodies, base64 attachments, custom headers (with a reserved-header blocklist), and tags.
- Bearer API keys (`dp_` prefix) stored as SHA-256 hashes with scopes (`send`, `read:activity`), expiry, rotation, and last-used telemetry. Plaintext shown once.
- **Idempotency keys** — safe client retries without duplicate sends.
- **Per-key rate limiting** on the send endpoint.
- Total-recipient cap of 50 per message (the SES raw-send limit), up to 25 attachments / 30 MB.

### Delivery pipeline

- Full MIME messages built server-side and archived as `.eml` files for exact-copy download and resend.
- Queued delivery via SES v2 raw send (`aws-sdk-sesv2`) with retries and backoff; clean status state machine (`queued → sending → sent → delivered/bounced/...`).
- Guardrails before accepting a send: from-address must use a verified domain, SES quota freshness check, and a complaint-rate circuit breaker.

### Event tracking & suppressions

- SNS webhook ingestion with signature verification and automatic subscription confirmation.
- Per-recipient event log: delivery, bounce (hard/soft with diagnostics), complaint, open, click, rejection, delay.
- Automatic suppression on complaints and permanent bounces — soft bounces never suppress. Suppressions support expiry (`expires_at` is honored) and manual management.

### Dashboard

- Server-rendered with Hotwire (Turbo + Stimulus); live activity updates over Solid Cable — no separate frontend build.
- Activity feed with search, time ranges, and metric tiles (sent, delivery/open/click/bounce rates, complaints) with period-over-period deltas and sparklines.
- Email inspector: full detail, event timeline, sandboxed HTML preview (strict CSP), raw `.eml` download, one-click resend.
- Bounce queues with bulk "retry soft bounces", suppression management, CSV export.

### Domains & identities

- Add a sending domain → Departures creates the SES identity and surfaces the DKIM CNAME records → one-click DNS re-check until verified.
- Per-project sending sources with their own SES region, configuration set, credentials (encrypted at rest with Active Record encryption), and quota cache.

### Outbound webhooks

- Subscribe your endpoints to email events; deliveries are HMAC-SHA256 signed (`Departures-Signature: t={ts},v1={sig}`) with retries, backoff, and a full per-attempt delivery log with success-rate stats.

### Templates

- Reusable templates with `{{ variable }}` substitution for subject, HTML, and text parts.

### Multi-tenancy & access control

- Workspaces → projects hierarchy. Users can belong to multiple workspaces with a workspace switcher and a proper invitation flow.
- Six roles per workspace (`owner`, `member`, `sender`, `api_keys`, `domains`, `read_only`) mapped to capabilities; every mutating action is authorized against them.
- Registration is open only for the first user (who becomes owner) or when `OPEN_REGISTRATION` is set.

### Operations

- Scheduled maintenance via Solid Queue recurring jobs: SES quota sync and data retention pruning (emails, `.eml` files, webhook logs, expired idempotency keys and invitations).
- Health check at `/up`; deployable anywhere as a Docker container with Kamal.

## Tech stack

| Layer | Choice |
|---|---|
| Framework | Rails 8.1, Ruby 3.4 |
| Database | SQLite |
| Jobs / cache / websockets | Solid Queue / Solid Cache / Solid Cable (database-backed, no Redis) |
| Frontend | Hotwire (Turbo + Stimulus), import maps, Propshaft, hand-written CSS |
| Email delivery | Amazon SES v2 (`aws-sdk-sesv2`) |
| Deployment | Docker + Kamal |

The entire stack runs as a single app plus a job worker — no Redis, no Node build step, no external services beyond AWS.

## Getting started

```bash
git clone https://github.com/<your-org>/departures.git
cd departures
bundle install
bin/rails db:prepare
bin/dev
```

Registration is open only for the first user; set `OPEN_REGISTRATION=1` to allow more sign-ups.

Run the test suite:

```bash
bin/rails test
```

The `minitest` gem is pinned to `~> 5.25` because minitest 6 removed `minitest/mock`, which the delivery-job tests rely on.

Full documentation — dashboard guides, API reference, webhooks, and self-hosting — is built into the
app at `/docs` (no account needed). For production setup start with `/docs/self-hosting-quickstart`.

## API

### Authentication

Every request carries a bearer API key:

```
Authorization: Bearer dp_...
```

Keys are scoped (`send`, `read:activity`); a key missing the scope required by the endpoint gets a `403`. An invalid, revoked, or expired token gets a `401`.

### `POST /api/emails`

Accepts a message for sending. `to`, `cc`, and `bcc` are always arrays, even for a single recipient:

```bash
curl -i -X POST https://your-departures-host/api/emails \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: order-42-confirmation" \
  -d '{
    "from": "hello@example.com",
    "to": ["user@example.com"],
    "cc": [],
    "bcc": [],
    "subject": "Welcome",
    "html": "<p>Hi there</p>",
    "text": "Hi there",
    "headers": {},
    "tags": {},
    "attachments": [
      { "filename": "invoice.pdf", "content_type": "application/pdf", "content": "<base64>" }
    ]
  }'
```

Send either `subject` + a body (`html` and/or `text`), or a `template_id` — not both. Up to 50 total recipients across `to`/`cc`/`bcc`, up to 25 attachments capped at 30 MB decoded total.

An optional `environment` param selects which of the project's sources (environments) to send through, defaulting to `production`. An unknown environment returns `422`.

A successful request returns `202 Accepted` immediately — the email is queued, not yet delivered:

```json
{ "id": "em_9Y6g1q2Flh4CvFzlKCFzUjO6" }
```

Delivery then happens asynchronously through SES: the email's status advances `queued → sending → sent`. If SES rejects the send, delivery is retried with backoff up to 3 attempts; on final failure the email is marked `failed` and the reason is recorded in `failure_reason`.

### Idempotency

Pass an `Idempotency-Key` header to make retries safe. Replaying the exact same request body with the same key returns the original email's `id` without creating a second send. Reusing the same key with a **different** body returns `409 Conflict`:

```json
{ "error": "Idempotency-Key was already used with a different request body" }
```

### `GET /api/emails`

Lists the calling key's project's 50 most recent emails (requires the `read:activity` scope):

```json
{ "data": [ { "id": "em_9Y6g1q2Flh4CvFzlKCFzUjO6", "status": "queued", "created_at": "2026-07-08T13:04:40.146Z" } ] }
```

### SES event webhook (inbound)

Each source has a secret webhook token; subscribe its SNS topic (the SES configuration set's event destination) to:

```
POST /api/webhooks/ses/:webhook_token
```

Subscription confirmations are handled automatically. Every notification is SNS-signature-verified (signing-cert host pinned to `sns.<region>.amazonaws.com`) and logged, then processed in the background: events are matched to emails by SES message id, recorded per recipient, and the email's status advances monotonically (`sent → delivered → opened → clicked`, or `bounced`/`complained`) — out-of-order events never regress status. Complaints and permanent bounces suppress the recipient automatically (soft bounces never do; expired suppressions are reactivated). Unknown tokens 404, bad signatures 403, and the endpoint is throttled to 120 requests/minute per token.

### Rate limiting

Each API key is limited to 60 requests per minute. Exceeding it returns `429 Too Many Requests`:

```json
{ "error": "Too many requests" }
```

### Error format

| Status | When | Body |
|---|---|---|
| 401 | Missing, unknown, revoked, or expired token | `{ "error": "Unauthorized" }` |
| 403 | Key lacks the required scope | `{ "error": "Forbidden: this key is missing the <scope> scope" }` |
| 409 | Idempotency key reused with a different body | `{ "error": "..." }` |
| 422 | Validation failure (bad recipients, suppressed address, unknown environment, etc.) | `{ "errors": ["..."] }` |
| 429 | Rate limit exceeded | `{ "error": "Too many requests" }` |

## Contributing

- [Mario Alvarez](https://github.com/marioalna)
- [Jorge Alvarez](https://github.com/jorgegorka)

Contributions are welcome. Please open an issue before sending a PR.

### Acknowledgements

Departures is inspired by [Larasend](https://github.com/savvyagents/larasend), a self-hosted SES control plane built with Laravel. We evaluated Larasend's feature set and architecture in depth (see `docs/larasend-evaluation-and-plan.md`) and set out to build the same core ideas natively on Rails — while adding improvements such as idempotency keys, send-endpoint rate limiting, expiry-aware suppressions, retention jobs, and full multi-workspace tenancy. Thanks to the Larasend authors for open-sourcing their work.

## License

Departures is open source under the [MIT License](LICENSE). You are free to download, clone, modify, and self-host it.

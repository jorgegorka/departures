# Departures

Departures is a self-hosted transactional email platform built on Ruby on Rails. It acts as a control plane for Amazon SES: your applications send mail through a simple HTTP API, and Departures handles delivery through SES, tracks the full delivery lifecycle (deliveries, bounces, complaints, opens, clicks), maintains suppression lists, relays events to your own webhooks, and gives you an activity dashboard to inspect everything.

You run it yourself, on your own infrastructure, against your own AWS account. No per-email pricing, no third-party data processor — just SES rates and a single Rails app.

> **Status:** Under active development. The feature set below describes the target scope; see `docs/` for the evaluation and implementation plan.

## How it works

1. Your app makes a `POST /api/emails` request with a bearer API key (or uses a drop-in Action Mailer delivery method, planned as a companion gem).
2. Departures validates the request, checks guardrails (verified sending domain, suppression list, SES quota, complaint-rate circuit breaker), builds the full MIME message, persists it, and queues delivery through SES v2 raw send.
3. SES delivery events flow back via SNS to a per-source webhook endpoint. Departures verifies the SNS signature, records each event, advances the email's status, creates suppressions where appropriate, updates the dashboard in real time, and fans events out to your webhook endpoints.

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

Detailed setup (AWS credentials, SNS topic wiring, deployment) will be documented as the corresponding features land.

## Contributing

- [Mario Alvarez](https://github.com/marioalna)
- [Jorge Alvarez](https://github.com/jorgegorka)

Contributions are welcome. Please open an issue before sending a PR.

### Acknowledgements

Departures is inspired by [Larasend](https://github.com/savvyagents/larasend), a self-hosted SES control plane built with Laravel. We evaluated Larasend's feature set and architecture in depth (see `docs/larasend-evaluation-and-plan.md`) and set out to build the same core ideas natively on Rails — while adding improvements such as idempotency keys, send-endpoint rate limiting, expiry-aware suppressions, retention jobs, and full multi-workspace tenancy. Thanks to the Larasend authors for open-sourcing their work.

## License

Departures is open source under the [MIT License](LICENSE). You are free to download, clone, modify, and self-host it.

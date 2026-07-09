# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Departures is a self-hosted transactional email platform: a Rails control plane for Amazon SES. Apps send mail through `POST /api/emails`; Departures builds and archives the MIME message, delivers via SES v2 raw send, ingests delivery events back from SNS, manages suppressions, fans events out to customer webhooks, and renders a live Hotwire dashboard.

Stack: Rails 8.1, Ruby 3.4, SQLite, Solid Queue/Cache/Cable (no Redis), Hotwire (Turbo + Stimulus), import maps + Propshaft (no Node build), hand-written CSS, `aws-sdk-sesv2`, Kamal.

## Commands

```sh
bin/setup                # install deps, prepare DB
bin/dev                  # run the app (web + jobs)
bin/rails test           # full Minitest suite (parallelized, fixtures :all)
bin/rails test test/models/email_test.rb        # one file
bin/rails test test/models/email_test.rb:42     # one test by line
bin/rubocop              # style (rubocop-rails-omakase)
bin/ci                   # full CI: setup, rubocop, bundler-audit, importmap audit, brakeman, tests, seed replant
bin/jobs                 # Solid Queue worker alone
```

`bin/rails test` and `bin/rubocop` must both be green at the end of every task.

## Project docs are binding

The build is driven by plans and pattern documents in `docs/` — read the relevant ones before implementing:

- `docs/plans/departures-execution-plan.md` — master phase-by-phase plan; Section A holds pattern directives every task inherits (tenancy, model layer, naming). Per-phase TDD plans live alongside it in `docs/plans/`.
- `docs/patterns-and-best-practices.md` — the Rails style this codebase follows (concern-heavy models, thin controllers, `_now`/`_later` jobs, presenters as plain Ruby classes).
- `docs/style-guide.md` — CSS architecture: pure custom CSS, OKLCH color tokens, `@layer` organization. No CSS frameworks.
- `docs/larasend-evaluation-and-plan.md` — full feature scope.

Hard constraints from the plan: default integer primary keys (not UUIDs); no new gems beyond what's in the Gemfile (no Devise, rack-attack, state-machine gems, CSS frameworks); API key prefix `dp_`; webhook signature header `Departures-Signature`; MIME id header `X-Departures-Id`; `!` methods only when a non-bang counterpart exists (so `mark_sent`, `apply_event`, `sync_quota` — no bang); registration open only while `User.none?` or `ENV["OPEN_REGISTRATION"]` is set.

## Architecture

### Two entry paths

**Send path:** `Api::EmailsController` → `EmailSubmission` (form-object-style model that validates, checks guardrails, persists the `Email` graph) → MIME built by `Email::MimeBuilder` and archived as `.eml` via `Email::MimeStore` → `SendEmailJob` → `Email::Deliverable#deliver` calls SES v2 raw send. Status state machine in `Email::Statuses` (`queued → sending → sent → delivered/bounced/…`). Delivery is at-least-once by design.

**Event path:** SNS posts to `POST api/webhooks/ses/:webhook_token` (`Webhooks::SesController`, per-`Source` token). The controller verifies the SNS signature (`lib/sns/message_verifier.rb`), persists a `WebhookLog`, then `ProcessSesEventJob` → `Email::SesEvent` applies the event: creates `EmailEvent` rows per recipient, advances email status, creates `Suppression`s on complaints/hard bounces, and broadcasts dashboard updates.

### Multi-tenancy (the most important invariant)

Hierarchy: `Workspace → Project → Source/Email/...`. `Current` (ActiveSupport::CurrentAttributes) carries `session`, `user`, `workspace`, `project`.

- Dashboard controllers ALWAYS scope through `Current.user.workspaces` / `Current.workspace.projects` — never unscoped `Model.find`. Cross-tenant access must 404 (RecordNotFound), never 403.
- On the API, the bearer API key is the tenant boundary: `Api::BaseController` sets `Current.workspace`/`Current.project` from the key. No sessions or cookies there.
- Jobs inherit tenancy automatically: `config/initializers/active_job.rb` prepends an extension that captures `Current.workspace` at enqueue, serializes it as a GlobalID, and restores it in `perform_now`. **Never pass workspace as a job argument.**
- That initializer also sets `enqueue_after_transaction_commit = true` — `perform_later` inside a transaction is deferred to commit (the Rails 8.1 config key is silently ignored; it must be set there).

### Model layer conventions

Business logic lives in models composed from concerns; jobs are ultra-thin wrappers (`SendEmailJob` just calls `email.deliver`) exposed via `_later` methods on the model (`Email#deliver_later`, `WebhookLog#process_later`). Model-specific concerns go in a directory named after the model (`app/models/email/statuses.rb` → `Email::Statuses`); shared concerns in `app/models/concerns/` with adjective names (`Broadcastable`). Lambda association defaults are used for denormalized tenancy: `belongs_to :workspace, default: -> { project.workspace }`.

Roles/authorization: six workspace roles defined in `Workspace::Roles`, enforced in dashboard controllers via the `AuthorizesCapability` concern. API scopes (`send`, `read:activity`) enforced in `Api::BaseController`.

### Testing

Minitest + fixtures only (no RSpec, no factories). Tests run parallelized with `fixtures :all`; `test/test_helper.rb` provides `wipe_send_domain` / `wipe_workspace_records` helpers for tests needing clean absolute counts. minitest is pinned to 5.x because job tests rely on `minitest/mock`'s `Object#stub`. AWS clients are stubbed (`Aws::SESV2::Client.new` via stubs), never hit for real.

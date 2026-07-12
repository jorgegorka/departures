# Phase 10 — Documentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a public, in-app documentation section at `/docs` — 18 hand-written pages covering getting started, every dashboard feature, the API, webhooks, and self-hosting — plus contextual "Learn more" links throughout the dashboard, a global header Docs link, README updates, and slimmed `docs/ops/` runbooks.

**Architecture:** A plain-Ruby page registry (`Docs::Page`) is the single source of truth for slugs, titles, and sections; it drives the route whitelist (unknown slugs 404 via `ActiveRecord::RecordNotFound`), the sidebar, the landing page, and the table-driven tests. Pages are hand-written ERB partials (no markdown gem) rendered by one thin, fully public `DocsController` inside a dedicated `docs` layout (two-column: sticky sidebar + prose content). A `docs_link_to` helper gives dashboard views fail-fast contextual links.

**Tech Stack:** Rails 8.1, hand-written CSS on the existing OKLCH token system (`@layer modules`), Minitest + fixtures. No new gems, no JavaScript needed.

## Global Constraints

- No new gems. No markdown rendering — pages are ERB.
- Thin RESTful controllers (master plan A3): `DocsController` has only `index` and `show`.
- Docs are **public**: `allow_unauthenticated_access`, `allow_unonboarded_access`, `allow_two_factor_unenrolled_access` (the `PasswordsController` pattern). No `Current`-scoped data may appear on any docs page.
- Unknown slugs raise `ActiveRecord::RecordNotFound` → 404 (consistent with the tenancy 404 convention).
- CSS: tokens only, no raw color values; new CSS in `@layer modules`; logical properties; verify light + dark; WCAG 2.1 AA (≥4.5:1 body contrast, visible focus).
- Copy voice (PRODUCT.md): friendly, clear, plain language over jargon — "translate, don't transcribe" SES concepts. Monospace only for literal code (IDs, headers, payloads).
- Facts in docs pages must match the implementation. Key invariants, verbatim: API key prefix `dp_`; webhook signature header `Departures-Signature: t=<ts>,v1=<hmac>`; MIME id header `X-Departures-Id`; ≤50 total recipients; ≤25 attachments / 30 MB; 60 req/min per key; idempotency keys expire after 24 h; suppression only on complaints + permanent bounces; registration open only while `User.none?` or `OPEN_REGISTRATION` is set.
- Every task ends with `bin/rails test` and `bin/rubocop` green, then a commit on `master`.

## Standards preludes

Before each task, re-read the named sections:

- **All tasks:** `docs/patterns-and-best-practices.md` Part 4 (controllers/views); master plan Section A.
- **Task 1 (layout + CSS):** `PRODUCT.md` and `DESIGN.md` (required by AGENTS.md before UI work), `docs/style-guide.md` tokens/dark-mode. Note: `app/views/layouts/application.html.erb` and `app/assets/stylesheets/nav.css` are under active redesign (`.shell-header`, `.wordmark`) — **re-read both immediately before editing** and reuse their current classes.
- **Tasks 2–6 (content):** the source material named in each task. Do not invent facts — every claim must trace to the named source file.

---

### Task 1: Docs skeleton — registry, route, controller, layout, CSS, first page

**Files:**
- Create: `app/models/docs/page.rb`
- Create: `app/controllers/docs_controller.rb`
- Create: `app/views/layouts/_head.html.erb`
- Create: `app/views/layouts/docs.html.erb`
- Create: `app/views/docs/_sidebar.html.erb`
- Create: `app/views/docs/index.html.erb`
- Create: `app/views/docs/show.html.erb`
- Create: `app/views/docs/pages/_getting_started.html.erb`
- Create: `app/assets/stylesheets/docs.css`
- Modify: `config/routes.rb` (after the `resources :exports` block)
- Modify: `app/views/layouts/application.html.erb` (replace `<head>…</head>` with the shared partial)
- Test: `test/models/docs/page_test.rb`, `test/controllers/docs_controller_test.rb`

**Interfaces:**
- Produces: `Docs::Page.all` → array of entries (`#slug`, `#title`, `#section`, `#partial`, `#to_param`); `Docs::Page.find(slug)` → entry or raises `ActiveRecord::RecordNotFound`; `Docs::Page.sections` → ordered `{ section_title => [entries] }`; routes `docs_path` / `doc_path(slug)`. Every later task adds entries to `Docs::Page::PAGES` and a matching partial under `app/views/docs/pages/`.

- [ ] **Step 1: Write the failing model test**

Create `test/models/docs/page_test.rb`:

```ruby
require "test_helper"

class Docs::PageTest < ActiveSupport::TestCase
  test "find returns the entry for a registered slug" do
    page = Docs::Page.find("getting-started")

    assert_equal "Getting started", page.title
    assert_equal "getting_started", page.partial
  end

  test "find raises RecordNotFound for an unknown slug" do
    assert_raises(ActiveRecord::RecordNotFound) { Docs::Page.find("bogus") }
  end

  test "every registered page has a template on disk" do
    Docs::Page.all.each do |page|
      path = Rails.root.join("app/views/docs/pages/_#{page.partial}.html.erb")

      assert path.exist?, "Missing template for docs page #{page.slug}: #{path}"
    end
  end

  test "every registered page belongs to a known section" do
    Docs::Page.all.each do |page|
      assert_includes Docs::Page::SECTIONS, page.section
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/models/docs/page_test.rb`
Expected: FAIL — `NameError: uninitialized constant Docs`

- [ ] **Step 3: Implement the registry**

Create `app/models/docs/page.rb`:

```ruby
class Docs::Page
  Entry = Data.define(:slug, :title, :section) do
    def partial = slug.tr("-", "_")
    def to_param = slug
  end

  SECTIONS = [
    "Getting started",
    "Dashboard guides",
    "API reference",
    "Webhooks",
    "Self-hosting & operations"
  ].freeze

  PAGES = [
    Entry.new(slug: "getting-started", title: "Getting started", section: "Getting started")
  ].freeze

  class << self
    def all
      PAGES
    end

    def find(slug)
      PAGES.find { |page| page.slug == slug } ||
        raise(ActiveRecord::RecordNotFound.new("Couldn't find docs page #{slug.inspect}", "Docs::Page", :slug, slug))
    end

    def sections
      SECTIONS.index_with { |section| PAGES.select { |page| page.section == section } }
    end
  end
end
```

- [ ] **Step 4: Run the model test to verify it passes**

Run: `bin/rails test test/models/docs/page_test.rb`
Expected: FAIL on "template on disk" only (partial not created yet) — the other three PASS. The partial arrives in Step 7.

- [ ] **Step 5: Write the failing controller test**

Create `test/controllers/docs_controller_test.rb`:

```ruby
require "test_helper"

class DocsControllerTest < ActionDispatch::IntegrationTest
  test "index renders for an anonymous visitor" do
    get docs_path

    assert_response :success
    assert_select "h1", text: "Documentation"
  end

  test "every registered page renders for an anonymous visitor" do
    Docs::Page.all.each do |page|
      get doc_path(page.slug)

      assert_response :success, "Docs page #{page.slug} did not render"
      assert_select "h1"
    end
  end

  test "an unknown slug responds with 404" do
    get doc_path("bogus")

    assert_response :not_found
  end

  test "a signed-in user with an unonboarded workspace is not redirected away" do
    workspaces(:acme).update!(onboarded_at: nil)
    sign_in_as users(:owner)

    get docs_path

    assert_response :success
  end
end
```

- [ ] **Step 6: Run it to verify it fails**

Run: `bin/rails test test/controllers/docs_controller_test.rb`
Expected: FAIL — `NameError: undefined local variable or method 'docs_path'`

- [ ] **Step 7: Implement route, controller, layouts, views, CSS**

In `config/routes.rb`, after the `resources :exports, only: :show` line:

```ruby
resources :docs, only: %i[ index show ], param: :slug
```

Create `app/controllers/docs_controller.rb`:

```ruby
class DocsController < ApplicationController
  allow_unauthenticated_access
  allow_unonboarded_access
  allow_two_factor_unenrolled_access

  layout "docs"

  def index
  end

  def show
    @page = Docs::Page.find(params[:slug])
  end
end
```

Create `app/views/layouts/_head.html.erb` by moving the entire `<head>…</head>` element out of `app/views/layouts/application.html.erb` **verbatim, as it exists at edit time** (the layout is under active redesign — re-read it first). As of writing it is:

```erb
<head>
  <title><%= content_for(:title) || "Departures" %></title>
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="application-name" content="Departures">
  <meta name="mobile-web-app-capable" content="yes">
  <%= csrf_meta_tags %>
  <%= csp_meta_tag %>
  <%= turbo_refreshes_with method: :morph, scroll: :preserve %>
  <meta name="view-transition" content="same-origin">

  <%= yield :head %>

  <%# Enable PWA manifest for installable apps (make sure to enable in config/routes.rb too!) %>
  <%#= tag.link rel: "manifest", href: pwa_manifest_path(format: :json) %>

  <link rel="icon" href="/icon.png" type="image/png">
  <link rel="icon" href="/icon.svg" type="image/svg+xml">
  <link rel="apple-touch-icon" href="/icon.png">

  <%# Includes all stylesheet files in app/assets/stylesheets %>
  <%= stylesheet_link_tag :app, "data-turbo-track": "reload" %>
  <%= javascript_importmap_tags %>
</head>
```

In `app/views/layouts/application.html.erb`, replace that element with:

```erb
<%= render "layouts/head" %>
```

Create `app/views/layouts/docs.html.erb` (reuses the current `.shell-header`/`.wordmark` shell so docs feel like the same product; auth-aware action on the right):

```erb
<!DOCTYPE html>
<html>
  <%= render "layouts/head" %>

  <body>
    <header class="shell-header">
      <div class="shell-header__identity center main-width">
        <%= link_to root_path, class: "wordmark" do %>Departures<span class="wordmark__dot" aria-hidden="true">.</span><% end %>
        <div class="shell-header__actions">
          <% if authenticated? %>
            <%= link_to "Dashboard", root_path, class: "btn btn--plain" %>
          <% else %>
            <%= link_to "Sign in", new_session_path, class: "btn btn--plain" %>
          <% end %>
        </div>
      </div>
    </header>
    <div class="docs-layout center pad main-width">
      <aside class="docs-sidebar">
        <%= render "docs/sidebar" %>
      </aside>
      <main id="main" class="docs-content">
        <%= yield %>
      </main>
    </div>
  </body>
</html>
```

Create `app/views/docs/_sidebar.html.erb` (registry-driven; empty sections hidden so early tasks never show dead headings):

```erb
<nav class="docs-nav" aria-label="Documentation">
  <%= link_to "Documentation", docs_path, class: "docs-nav__link docs-nav__link--home",
        aria: { current: current_page?(docs_path) ? "page" : nil } %>
  <% Docs::Page.sections.each do |section, pages| %>
    <% next if pages.empty? %>
    <h2 class="docs-nav__section"><%= section %></h2>
    <ul class="docs-nav__list">
      <% pages.each do |page| %>
        <li>
          <%= link_to page.title, doc_path(page), class: "docs-nav__link",
                aria: { current: current_page?(doc_path(page)) ? "page" : nil } %>
        </li>
      <% end %>
    </ul>
  <% end %>
</nav>
```

Create `app/views/docs/index.html.erb` (registry-driven, so it can never link a missing page):

```erb
<% content_for :title, "Documentation — Departures" %>

<h1>Documentation</h1>
<p class="docs-lead">Everything you need to run Departures, wire your apps to it, and keep mail flowing.</p>

<% Docs::Page.sections.each do |section, pages| %>
  <% next if pages.empty? %>
  <section>
    <h2><%= section %></h2>
    <ul>
      <% pages.each do |page| %>
        <li><%= link_to page.title, doc_path(page) %></li>
      <% end %>
    </ul>
  </section>
<% end %>
```

Create `app/views/docs/show.html.erb`:

```erb
<% content_for :title, "#{@page.title} — Departures documentation" %>

<%= render "docs/pages/#{@page.partial}" %>
```

Create `app/views/docs/pages/_getting_started.html.erb`:

```erb
<h1>Getting started</h1>

<p>
  Departures is a self-hosted transactional email platform: a control plane for Amazon SES that you
  run on your own infrastructure. Your applications send mail through a simple HTTP API; Departures
  delivers it through SES, tracks the full delivery lifecycle, maintains suppression lists, relays
  events to your own webhooks, and shows everything live in the dashboard.
</p>

<h2>How a send works</h2>

<ol>
  <li>Your app calls <code>POST /api/emails</code> with a bearer API key — or uses the
    <%= link_to "Ruby gem", doc_path("getting-started") %>'s drop-in Action Mailer delivery method.</li>
  <li>Departures validates the request, checks guardrails (verified sending domain, suppression list,
    SES quota, complaint-rate circuit breaker), builds the full MIME message, archives it, and queues
    delivery through SES.</li>
  <li>SES delivery events flow back to Departures, which records each one, advances the email's status,
    creates suppressions where appropriate, updates the dashboard in real time, and fans events out to
    your webhook endpoints.</li>
</ol>

<h2>First-run setup</h2>

<p>
  After signing in for the first time, the onboarding checklist walks you through the four steps that
  get your first email out the door:
</p>

<ol>
  <li><strong>Add a source</strong> — the SES credentials and region Departures sends with.</li>
  <li><strong>Verify a domain</strong> — add your sending domain and create its DKIM records.
    Sends from unverified domains are rejected.</li>
  <li><strong>Issue an API key</strong> — your apps authenticate to the API with it.</li>
  <li><strong>Send a test email</strong> — prove the pipeline end to end.</li>
</ol>

<p>
  Registration is open only for the very first user, who becomes the workspace owner. To let more
  people sign up directly, set the <code>OPEN_REGISTRATION</code> environment variable — or simply
  invite teammates from the workspace settings, which always works.
</p>
```

The `link_to … doc_path("getting-started")` self-reference above is temporary scaffolding for the link-integrity rule (the Ruby gem page doesn't exist yet); Task 6 repoints it to `doc_path("ruby-gem")`.

Create `app/assets/stylesheets/docs.css`:

```css
@layer modules {
  /* Docs: two-column shell — sticky section nav beside a measured prose column. */
  .docs-layout {
    align-items: start;
    display: grid;
    gap: var(--space-2xl);
    grid-template-columns: 13rem minmax(0, 1fr);
    padding-block: var(--space-lg);
  }

  .docs-sidebar {
    inset-block-start: var(--space-lg);
    position: sticky;
  }

  .docs-nav__section {
    color: var(--color-ink-lighter);
    font-size: var(--text-x-small);
    font-weight: 600;
    letter-spacing: 0.04em;
    margin-block: var(--space-md) var(--space-2xs);
    text-transform: uppercase;
  }

  .docs-nav__list {
    display: grid;
    gap: 1px;
    list-style: none;
    margin: 0;
    padding: 0;
  }

  .docs-nav__link {
    border-radius: 0.375rem;
    color: var(--color-ink-light);
    display: block;
    font-size: var(--text-small);
    padding: 0.3em 0.6em;
    text-decoration: none;

    &:hover {
      background-color: var(--color-surface-sunken);
      color: var(--color-ink);
    }

    &[aria-current="page"] {
      background-color: var(--color-surface-sunken);
      color: var(--color-ink);
      font-weight: 600;
    }
  }

  .docs-nav__link--home {
    font-weight: 600;
    margin-block-end: var(--space-xs);
  }

  .docs-content {
    max-inline-size: 72ch;
    min-inline-size: 0;

    h1 {
      font-size: var(--text-large);
      margin-block-end: var(--space-sm);
    }

    h2 {
      font-size: var(--text-medium);
      margin-block: var(--space-xl) var(--space-xs);
    }

    p,
    li {
      line-height: 1.65;
    }

    ol,
    ul {
      padding-inline-start: 1.5em;
    }

    pre {
      background-color: var(--color-surface-sunken);
      border: 1px solid var(--color-border);
      border-radius: 0.5rem;
      font-size: var(--text-small);
      line-height: 1.5;
      margin-block: var(--space-md);
      overflow-x: auto;
      padding: var(--space-sm) var(--space-md);
    }

    table {
      border-collapse: collapse;
      font-size: var(--text-small);
      inline-size: 100%;
      margin-block: var(--space-md);
    }

    th {
      color: var(--color-ink-light);
      font-weight: 600;
      text-align: start;
    }

    th,
    td {
      border-block-end: 1px solid var(--color-border);
      padding: var(--space-xs) var(--space-sm) var(--space-xs) 0;
      vertical-align: top;
    }
  }

  .docs-lead {
    color: var(--color-ink-light);
    font-size: var(--text-medium);
  }

  @media (max-width: 48rem) {
    .docs-layout {
      grid-template-columns: 1fr;
    }

    .docs-sidebar {
      position: static;
    }
  }
}
```

- [ ] **Step 8: Run both test files to verify they pass**

Run: `bin/rails test test/models/docs/page_test.rb test/controllers/docs_controller_test.rb`
Expected: PASS (8 tests)

- [ ] **Step 9: Verify visually in both themes**

Run `bin/dev`, open `http://localhost:3000/docs` in a private window (logged out): landing renders with sidebar, shell header shows "Sign in"; `/docs/getting-started` renders; `/docs/bogus` 404s. Toggle OS dark mode and re-check contrast. Sign in and confirm the regular dashboard still renders correctly after the `_head` extraction.

- [ ] **Step 10: Run the full suite and rubocop, then commit**

Run: `bin/rails test && bin/rubocop`
Expected: green, no offenses

```bash
git add app/models/docs app/controllers/docs_controller.rb app/views/layouts app/views/docs app/assets/stylesheets/docs.css config/routes.rb test/models/docs test/controllers/docs_controller_test.rb
git commit -m "feat: public in-app docs section — registry, controller, layout, getting-started page"
```

---

### Task 2: API reference pages + link-integrity test

Content sources: `README.md` §API (lines 103–194 — port largely verbatim), `app/controllers/api/base_controller.rb`, `app/models/api_key.rb`, `app/models/idempotency_key.rb`, `app/models/email_submission.rb`.

**Files:**
- Modify: `app/models/docs/page.rb` (add two entries)
- Create: `app/views/docs/pages/_api_reference.html.erb`
- Create: `app/views/docs/pages/_api_keys.html.erb`
- Test: `test/integration/docs_links_test.rb` (new)

**Interfaces:**
- Consumes: `Docs::Page::PAGES`, `doc_path(slug)` from Task 1.
- Produces: registered slugs `api-reference` and `api-keys` (Task 7's contextual links target `api-keys`; Task 4's pages cross-link `api-reference`). The link-integrity test that every later content task must keep green.

- [ ] **Step 1: Write the failing link-integrity test**

Create `test/integration/docs_links_test.rb`:

```ruby
require "test_helper"

class DocsLinksTest < ActionDispatch::IntegrationTest
  test "every internal docs link on every docs page resolves to a registered page" do
    paths = [ docs_path ] + Docs::Page.all.map { |page| doc_path(page) }

    paths.each do |path|
      get path

      assert_response :success
      css_select("a[href^='/docs']").each do |anchor|
        href = anchor["href"].split("#").first
        next if href == docs_path
        slug = href.delete_prefix("/docs/")

        assert Docs::Page.all.any? { |page| page.slug == slug },
          "#{path} links to unregistered docs page #{href}"
      end
    end
  end
end
```

Also register the two new pages in `app/models/docs/page.rb` — the `PAGES` array becomes:

```ruby
PAGES = [
  Entry.new(slug: "getting-started", title: "Getting started", section: "Getting started"),
  Entry.new(slug: "api-reference", title: "API reference", section: "API reference"),
  Entry.new(slug: "api-keys", title: "API keys", section: "API reference")
].freeze
```

- [ ] **Step 2: Run tests to verify the expected failure**

Run: `bin/rails test test/models/docs/page_test.rb test/integration/docs_links_test.rb`
Expected: FAIL — "Missing template for docs page api-reference" (model test) and a 500/missing-template failure in the crawl.

- [ ] **Step 3: Write the two page partials**

Create `app/views/docs/pages/_api_reference.html.erb`:

```erb
<h1>API reference</h1>

<p>
  The API is deliberately small: send an email, list recent emails. Everything else — inspection,
  suppressions, webhooks — lives in the dashboard.
</p>

<h2>Authentication</h2>

<p>Every request carries a bearer <%= link_to "API key", doc_path("api-keys") %>:</p>

<pre><code>Authorization: Bearer dp_...</code></pre>

<p>
  Keys are scoped (<code>send</code>, <code>read:activity</code>); a key missing the scope required
  by the endpoint gets a <code>403</code>. An invalid, revoked, or expired token gets a <code>401</code>.
</p>

<h2>POST /api/emails</h2>

<p>
  Accepts a message for sending (requires the <code>send</code> scope). <code>to</code>,
  <code>cc</code>, and <code>bcc</code> are always arrays, even for a single recipient:
</p>

<pre><code>curl -i -X POST https://your-departures-host/api/emails \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: order-42-confirmation" \
  -d '{
    "from": "hello@example.com",
    "to": ["user@example.com"],
    "cc": [],
    "bcc": [],
    "subject": "Welcome",
    "html": "&lt;p&gt;Hi there&lt;/p&gt;",
    "text": "Hi there",
    "headers": {},
    "tags": {},
    "attachments": [
      { "filename": "invoice.pdf", "content_type": "application/pdf", "content": "&lt;base64&gt;" }
    ]
  }'</code></pre>

<p>
  Send either <code>subject</code> plus a body (<code>html</code> and/or <code>text</code>), or a
  <code>template_id</code> with a <code>variables</code> map — not both. A template is referenced by
  its slug or numeric id. Up to 50 total recipients across <code>to</code>/<code>cc</code>/<code>bcc</code>,
  up to 25 attachments capped at 30&nbsp;MB decoded total.
</p>

<p>
  An optional <code>environment</code> parameter selects which of the project's sources to send
  through, defaulting to <code>production</code>. An unknown environment returns <code>422</code>.
</p>

<p>A successful request returns <code>202 Accepted</code> immediately — the email is queued, not yet delivered:</p>

<pre><code>{ "id": "em_9Y6g1q2Flh4CvFzlKCFzUjO6" }</code></pre>

<p>
  Delivery then happens asynchronously through SES: the status advances
  <code>queued → sending → sent</code>, and onward as delivery events arrive. If SES rejects the
  send, delivery is retried with backoff up to 3 attempts; on final failure the email is marked
  <code>failed</code> with the reason recorded. The id comes back to your app and is also stamped
  into the message as the <code>X-Departures-Id</code> header, so you can correlate an email in a
  recipient's inbox with its record in the dashboard.
</p>

<h2>Guardrails</h2>

<p>Departures rejects a send with <code>422</code> before it ever reaches SES when:</p>

<ul>
  <li>the <code>from</code> address does not use a verified sending domain,</li>
  <li>any recipient is on the project's suppression list (the response names the addresses),</li>
  <li>the source's SES quota information is stale and cannot be refreshed, or</li>
  <li>the complaint-rate circuit breaker has paused sending (at least 100 sends in the last 30 days
    with a complaint rate of 0.1% or more).</li>
</ul>

<h2>Idempotency</h2>

<p>
  Pass an <code>Idempotency-Key</code> header to make retries safe. Replaying the exact same request
  body with the same key returns the original email's <code>id</code> without creating a second send.
  Keys expire after 24 hours. Reusing a key with a <strong>different</strong> body returns
  <code>409 Conflict</code>:
</p>

<pre><code>{ "error": "Idempotency-Key was already used with a different request body" }</code></pre>

<h2>GET /api/emails</h2>

<p>Lists the calling key's project's 50 most recent emails (requires the <code>read:activity</code> scope):</p>

<pre><code>{ "data": [ { "id": "em_9Y6g1q2Flh4CvFzlKCFzUjO6", "status": "queued", "created_at": "2026-07-08T13:04:40.146Z" } ] }</code></pre>

<h2>Rate limiting</h2>

<p>Each API key is limited to 60 requests per minute. Exceeding it returns <code>429 Too Many Requests</code>:</p>

<pre><code>{ "error": "Too many requests" }</code></pre>

<h2>Errors</h2>

<table>
  <thead>
    <tr><th>Status</th><th>When</th><th>Body</th></tr>
  </thead>
  <tbody>
    <tr><td><code>401</code></td><td>Missing, unknown, revoked, or expired token</td><td><code>{ "error": "Unauthorized" }</code></td></tr>
    <tr><td><code>403</code></td><td>Key lacks the required scope</td><td><code>{ "error": "Forbidden: this key is missing the &lt;scope&gt; scope" }</code></td></tr>
    <tr><td><code>409</code></td><td>Idempotency key reused with a different body</td><td><code>{ "error": "..." }</code></td></tr>
    <tr><td><code>422</code></td><td>Validation failure (bad recipients, suppressed address, unknown environment, …)</td><td><code>{ "errors": ["..."] }</code></td></tr>
    <tr><td><code>429</code></td><td>Rate limit exceeded</td><td><code>{ "error": "Too many requests" }</code></td></tr>
  </tbody>
</table>
```

Create `app/views/docs/pages/_api_keys.html.erb`:

```erb
<h1>API keys</h1>

<p>
  API keys are how your applications authenticate to the <%= link_to "API", doc_path("api-reference") %>.
  Each key belongs to a project, carries a set of scopes, and can expire, be rotated, or be revoked
  at any time from the dashboard's <strong>API keys</strong> section.
</p>

<h2>Issuing a key</h2>

<p>
  Create a key with a name (so you can tell keys apart later), the scopes it needs, and an optional
  expiry date. The plaintext key — it starts with <code>dp_</code> — is shown <strong>once</strong>,
  on creation. Departures stores only a SHA-256 hash, so it cannot show the key again: copy it into
  your app's credential store right away.
</p>

<h2>Scopes</h2>

<table>
  <thead>
    <tr><th>Scope</th><th>Grants</th></tr>
  </thead>
  <tbody>
    <tr><td><code>send</code></td><td><code>POST /api/emails</code> — submitting email for delivery</td></tr>
    <tr><td><code>read:activity</code></td><td><code>GET /api/emails</code> — listing recent emails</td></tr>
  </tbody>
</table>

<p>Give each application only the scopes it needs — a key used solely for sending has no reason to read activity.</p>

<h2>Rotation and revocation</h2>

<p>
  <strong>Rotate</strong> revokes a key and issues a fresh one with the same name and scopes in a
  single step — the new plaintext is shown once, exactly like a new key. <strong>Revoke</strong>
  disables a key immediately; requests with it get <code>401</code> from that moment on.
</p>

<p>
  The key list shows last-used telemetry (when, from which IP and user agent), which makes it easy to
  spot keys that are no longer in use before revoking them. Issuing, revoking, and rotating keys are
  all recorded in the workspace audit log.
</p>
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/models/docs/page_test.rb test/controllers/docs_controller_test.rb test/integration/docs_links_test.rb`
Expected: PASS

- [ ] **Step 5: Verify visually, run the suite, commit**

Spot-check `/docs/api-reference` and `/docs/api-keys` in both themes (tables and code blocks especially).

Run: `bin/rails test && bin/rubocop`
Expected: green

```bash
git add app/models/docs/page.rb app/views/docs/pages test/integration/docs_links_test.rb
git commit -m "docs: API reference and API keys pages + link-integrity test"
```

---

### Task 3: Webhooks pages

Content sources: `app/models/webhook_endpoint.rb` (EVENT_TYPES), `app/models/webhook_log.rb` (`delivery_payload`), `app/models/webhook_delivery.rb` (signing, timeouts, SSRF guard), `README.md` §"SES event webhook (inbound)", `app/controllers/webhooks/ses_controller.rb`.

**Files:**
- Modify: `app/models/docs/page.rb` (add two entries)
- Create: `app/views/docs/pages/_outbound_webhooks.html.erb`
- Create: `app/views/docs/pages/_ses_sns_ingestion.html.erb`

**Interfaces:**
- Consumes: registry + link-integrity test from Tasks 1–2.
- Produces: registered slugs `outbound-webhooks` (Task 7 links it from the webhook endpoints view) and `ses-sns-ingestion` (Task 7 links it from the sources view; Task 5's deployment page cross-links it).

- [ ] **Step 1: Register the pages (failing test)**

In `app/models/docs/page.rb`, append to `PAGES`:

```ruby
Entry.new(slug: "outbound-webhooks", title: "Outbound webhooks", section: "Webhooks"),
Entry.new(slug: "ses-sns-ingestion", title: "SES event ingestion", section: "Webhooks")
```

Run: `bin/rails test test/models/docs/page_test.rb`
Expected: FAIL — missing templates for both slugs

- [ ] **Step 2: Write the page partials**

Create `app/views/docs/pages/_outbound_webhooks.html.erb`:

```erb
<h1>Outbound webhooks</h1>

<p>
  Departures can relay email events to your own HTTPS endpoints as they happen — so your app can
  react to a bounce, mark a user's address as bad, or log deliveries in your own systems. Manage
  endpoints in the dashboard's <strong>Webhooks</strong> section: each endpoint has a URL, a signing
  secret, and the set of event types it subscribes to.
</p>

<h2>Event types</h2>

<p>
  <code>send</code>, <code>delivery</code>, <code>open</code>, <code>click</code>, <code>bounce</code>,
  <code>complaint</code>, <code>delivery_delay</code>, <code>reject</code>,
  <code>rendering_failure</code>, <code>subscription</code>.
</p>

<h2>Payload</h2>

<pre><code>{
  "event": "delivery",
  "email_id": "em_9Y6g1q2Flh4CvFzlKCFzUjO6",
  "recipients": ["user@example.com"],
  "occurred_at": "2026-07-08T13:04:41.000Z",
  "payload": { ... }
}</code></pre>

<p>
  <code>email_id</code> is the same id the API returned when the email was submitted (and the value
  of its <code>X-Departures-Id</code> header). <code>payload</code> carries the underlying SES event
  verbatim, so diagnostic detail — bounce subtypes, SMTP responses, user agents — is never lost.
</p>

<h2>Verifying signatures</h2>

<p>
  Every delivery is signed. The endpoint's secret (it starts with <code>whsec_</code>) is shown once
  when the endpoint is created. Each request carries:
</p>

<pre><code>Departures-Signature: t=1720000000,v1=5257a869e7ecebeda32affa62cdca3fa51cad7e77a0e56ff536d0ce8e108d8bd</code></pre>

<p>
  <code>v1</code> is an HMAC-SHA256 of <code>"&lt;timestamp&gt;.&lt;raw request body&gt;"</code> using
  your endpoint's secret as the key. To verify:
</p>

<ol>
  <li>Split the header on commas into <code>t</code> and <code>v1</code>.</li>
  <li>Compute <code>HMAC_SHA256(secret, "#{t}.#{raw_body}")</code> over the <strong>raw</strong> body —
    before any JSON parsing.</li>
  <li>Compare against <code>v1</code> with a constant-time comparison, and reject stale timestamps
    (for example, older than 5 minutes) to prevent replays.</li>
</ol>

<pre><code># Ruby example (e.g. in a Rails controller)
timestamp, signature = request.headers["Departures-Signature"]
  .split(",").map { |part| part.split("=", 2).last }
expected = OpenSSL::HMAC.hexdigest("SHA256", ENV["WEBHOOK_SECRET"], "#{timestamp}.#{request.raw_post}")

unless Rack::Utils.secure_compare(expected, signature) && Time.at(timestamp.to_i) > 5.minutes.ago
  head :unauthorized and return
end</code></pre>

<h2>Delivery behavior</h2>

<ul>
  <li>Endpoints must be HTTPS. Requests are sent with <code>User-Agent: Departures-Webhooks</code>
    and a 5-second timeout.</li>
  <li>Delivery is <strong>at-least-once</strong>: a non-2xx response or timeout is retried with
    backoff, so your handler should be idempotent (the <code>email_id</code> + event type make a
    good deduplication key).</li>
  <li>Every attempt is logged — status, latency, and response snippet — and each endpoint shows its
    success rate. Delivery logs are kept for 30 days.</li>
</ul>
```

Create `app/views/docs/pages/_ses_sns_ingestion.html.erb`:

```erb
<h1>SES event ingestion</h1>

<p>
  Delivery events — deliveries, bounces, complaints, opens, clicks — flow from Amazon SES back to
  Departures through an SNS subscription. This is the wiring that turns "we handed the message to
  SES" into the live statuses you see in the dashboard. It is set up once per
  <%= link_to "source", doc_path("ses-sns-ingestion") %>.
</p>

<h2>Wiring it up</h2>

<p>
  Every source has its own secret webhook URL, shown on the source's page in the dashboard:
</p>

<pre><code>https://your-departures-host/api/webhooks/ses/&lt;webhook_token&gt;</code></pre>

<ol>
  <li>In the AWS console, open the SES <strong>configuration set</strong> the source sends through and
    add (or edit) its <strong>event destination</strong>, selecting the event types you want and
    pointing it at an SNS topic.</li>
  <li>Create an HTTPS <strong>subscription</strong> on that topic with the source's webhook URL as the
    endpoint.</li>
  <li>That's it — Departures confirms the subscription automatically. In the AWS console the
    subscription should show <em>Confirmed</em> within a few seconds.</li>
</ol>

<h2>What happens to each event</h2>

<p>
  Every notification is verified against its SNS signature (the signing certificate host is pinned to
  <code>sns.&lt;region&gt;.amazonaws.com</code>) and logged before processing. Events are matched to
  emails by SES message id and recorded per recipient; the email's status advances monotonically
  (<code>sent → delivered → opened → clicked</code>, or <code>bounced</code>/<code>complained</code>)
  — out-of-order events never regress a status. Complaints and permanent bounces add the recipient to
  the suppression list automatically; soft bounces never do. Matching events also fan out to your
  <%= link_to "outbound webhooks", doc_path("outbound-webhooks") %>.
</p>

<h2>Endpoint behavior</h2>

<ul>
  <li>Unknown tokens 404; invalid SNS signatures 403.</li>
  <li>The endpoint is throttled to 120 requests per minute per token.</li>
  <li>Processing is asynchronous: the endpoint acknowledges quickly and a background job applies the
    event, so a burst of notifications never blocks SNS.</li>
</ul>
```

The `doc_path("ses-sns-ingestion")` self-reference in the first paragraph is temporary scaffolding — Task 4 repoints it to `doc_path("sources")` once that page exists.

- [ ] **Step 3: Run the tests to verify they pass**

Run: `bin/rails test test/models/docs/page_test.rb test/controllers/docs_controller_test.rb test/integration/docs_links_test.rb`
Expected: PASS

- [ ] **Step 4: Verify visually, run the suite, commit**

Run: `bin/rails test && bin/rubocop`
Expected: green

```bash
git add app/models/docs/page.rb app/views/docs/pages
git commit -m "docs: outbound webhooks and SES event ingestion pages"
```

---

### Task 4: Dashboard guide pages (7)

Content sources: `README.md` §Features, `app/models/source.rb` + `app/models/source/quota.rb`, `app/models/domain.rb`, `app/models/template.rb` + `app/models/email_submission.rb` (subject XOR template), `app/models/email/resendable.rb`, `app/models/suppression.rb`, `app/models/workspace/roles.rb`, `app/models/audit_event.rb`, `app/models/user/two_factor.rb`, `app/controllers/registrations_controller.rb`. Verify each fact against the model before writing it.

**Files:**
- Modify: `app/models/docs/page.rb` (add seven entries)
- Modify: `app/views/docs/pages/_ses_sns_ingestion.html.erb` (repoint the temporary self-link to `doc_path("sources")`)
- Create: `app/views/docs/pages/_sources.html.erb`
- Create: `app/views/docs/pages/_domains_and_dkim.html.erb`
- Create: `app/views/docs/pages/_sending_and_templates.html.erb`
- Create: `app/views/docs/pages/_activity_and_inspecting_email.html.erb`
- Create: `app/views/docs/pages/_suppressions_and_bounces.html.erb`
- Create: `app/views/docs/pages/_workspaces_and_access.html.erb`
- Create: `app/views/docs/pages/_account_security.html.erb`

**Interfaces:**
- Consumes: registry + tests from Tasks 1–2; existing pages `api-reference`, `outbound-webhooks`, `ses-sns-ingestion` for cross-links.
- Produces: the seven "Dashboard guides" slugs exactly as listed below — Task 7's contextual links depend on these exact strings.

- [ ] **Step 1: Register the pages (failing test)**

In `app/models/docs/page.rb`, append to `PAGES`:

```ruby
Entry.new(slug: "sources", title: "Sources", section: "Dashboard guides"),
Entry.new(slug: "domains-and-dkim", title: "Domains & DKIM", section: "Dashboard guides"),
Entry.new(slug: "sending-and-templates", title: "Sending & templates", section: "Dashboard guides"),
Entry.new(slug: "activity-and-inspecting-email", title: "Activity & inspecting email", section: "Dashboard guides"),
Entry.new(slug: "suppressions-and-bounces", title: "Suppressions & bounces", section: "Dashboard guides"),
Entry.new(slug: "workspaces-and-access", title: "Workspaces & access", section: "Dashboard guides"),
Entry.new(slug: "account-security", title: "Account security", section: "Dashboard guides")
```

Run: `bin/rails test test/models/docs/page_test.rb`
Expected: FAIL — seven missing templates

- [ ] **Step 2: Repoint the temporary link in the SES ingestion page**

In `app/views/docs/pages/_ses_sns_ingestion.html.erb`, first paragraph, change
`<%= link_to "source", doc_path("ses-sns-ingestion") %>` to
`<%= link_to "source", doc_path("sources") %>`.

- [ ] **Step 3: Write the seven page partials**

Create `app/views/docs/pages/_sources.html.erb`:

```erb
<h1>Sources</h1>

<p>
  A source is the SES identity Departures sends with: an AWS region plus an access key and secret,
  stored encrypted. Each project can have one source per environment (for example
  <code>production</code> and <code>staging</code>), and API calls pick the source with the
  <code>environment</code> parameter — so your staging app can send through a sandboxed SES account
  while production uses the real one.
</p>

<h2>Adding a source</h2>

<ol>
  <li>Create an IAM user in the AWS account you send from, with permission to call SES
    (<code>ses:SendRawEmail</code> for delivery, plus <code>ses:GetAccount</code> for quota checks).</li>
  <li>In <strong>Sources</strong>, add the access key id, secret, and the SES region you operate in.</li>
  <li>Wire delivery events back: the source's page shows its unique webhook URL — follow
    <%= link_to "SES event ingestion", doc_path("ses-sns-ingestion") %> to connect it to your SES
    configuration set.</li>
</ol>

<h2>Quota</h2>

<p>
  Departures caches your SES sending quota and refreshes it automatically when it goes stale (older
  than six hours); you can also refresh it manually from the source's page. If the quota can't be
  refreshed, sends are rejected rather than risking silent SES throttling — see the guardrails on the
  <%= link_to "API reference", doc_path("api-reference") %>.
</p>
```

Create `app/views/docs/pages/_domains_and_dkim.html.erb`:

```erb
<h1>Domains & DKIM</h1>

<p>
  Before Departures accepts a send, the <code>from</code> address must use a domain you've verified.
  Verification proves to mailbox providers that mail from your domain is really yours — it's the
  single biggest factor in whether your email lands in the inbox.
</p>

<h2>Verifying a domain</h2>

<ol>
  <li>In <strong>Domains</strong>, add your sending domain. Departures creates the SES identity and
    shows the DKIM records you need.</li>
  <li>Create the three DKIM <code>CNAME</code> records at your DNS provider, exactly as shown.</li>
  <li>Use <strong>Check</strong> on the domain to re-query DNS. Propagation can take from minutes to
    a few hours depending on your provider; keep re-checking until the domain shows verified.</li>
</ol>

<p>
  Once verified, any address at the domain can be a <code>from</code> address. Sends from unverified
  domains are rejected with a <code>422</code> that says so.
</p>
```

Create `app/views/docs/pages/_sending_and_templates.html.erb`:

```erb
<h1>Sending & templates</h1>

<h2>Test emails</h2>

<p>
  <strong>Send test</strong> in the dashboard sends a real email through your source without touching
  the API — the quickest way to prove the pipeline end to end, and the final step of first-run
  onboarding. The test email goes through exactly the same delivery path as an API send, so you'll
  see it in the activity feed with its full event timeline.
</p>

<h2>Templates</h2>

<p>
  Templates let your app send structured data instead of pre-rendered bodies. A template holds a
  subject, an HTML body, a text body (at least one body is required), and a URL-friendly slug.
  Anywhere in those three parts you can write <code>{{ variable_name }}</code> placeholders.
</p>

<p>
  An API call then references the template instead of providing a subject and body — by slug or id —
  and supplies the values:
</p>

<pre><code>{
  "from": "hello@example.com",
  "to": ["user@example.com"],
  "template_id": "welcome-email",
  "variables": { "first_name": "Ada" }
}</code></pre>

<p>
  A send uses <em>either</em> a <code>subject</code> plus inline body <em>or</em> a
  <code>template_id</code> — never both. Values substituted into the HTML body are HTML-escaped
  automatically; subject and text parts are inserted as-is.
</p>
```

Create `app/views/docs/pages/_activity_and_inspecting_email.html.erb`:

```erb
<h1>Activity & inspecting email</h1>

<h2>The activity feed</h2>

<p>
  <strong>Activity</strong> is the live pulse of your sending: metric tiles (sent, delivery, open,
  click, and bounce rates, complaints) with period-over-period deltas and sparklines, above a
  searchable feed of recent email. It updates in real time as delivery events arrive — no refresh
  needed. Time-range and search controls narrow the view when you're investigating.
</p>

<h2>Inspecting an email</h2>

<p>Open any email to see everything Departures knows about it:</p>

<ul>
  <li><strong>Detail & timeline</strong> — sender, recipients, status, and the full per-recipient
    event history (delivered, opened, bounced with diagnostics, …).</li>
  <li><strong>Preview</strong> — the rendered HTML in a sandboxed frame.</li>
  <li><strong>Raw</strong> — the exact MIME message that went to SES, downloadable as an
    <code>.eml</code> file. Every send is archived byte-for-byte.</li>
  <li><strong>Resend</strong> — one click re-queues an exact copy (rebuilt from the archived
    message, attachments included) as a new email with its own tracking.</li>
</ul>

<h2>Finding an email</h2>

<p>
  Coming from the other direction — a user forwarded you a message and asked "why did I get this?" —
  check its headers: every email Departures sends carries its id in the
  <code>X-Departures-Id</code> header, which takes you straight to the email in the dashboard.
</p>
```

Create `app/views/docs/pages/_suppressions_and_bounces.html.erb`:

```erb
<h1>Suppressions & bounces</h1>

<h2>How suppression works</h2>

<p>
  When a recipient complains (marks your mail as spam) or hard-bounces (the address permanently
  doesn't exist), Departures adds them to the project's suppression list automatically. From then on,
  any send that includes them is rejected with a <code>422</code> naming the addresses — protecting
  your sender reputation before SES ever sees the message. Soft bounces (full mailbox, temporary
  server trouble) never suppress.
</p>

<h2>Managing the list</h2>

<p>
  <strong>Suppressions</strong> shows every suppressed address with its reason. You can add an
  address manually (an unsubscribe request, for example), remove one that no longer applies, or
  export the whole list as CSV. Suppressions can carry an expiry date; an expired suppression stops
  blocking sends, and re-suppressing the same address reactivates it.
</p>

<h2>Bounces</h2>

<p>
  <strong>Bounces</strong> lists bounced email with the diagnostic SES reported — hard or soft, the
  SMTP response, the exact recipient. Soft-bounced mail is often deliverable later (the mailbox was
  full, the server was down), so the bounce queue has a bulk <strong>retry</strong> action that
  re-sends soft-bounced messages.
</p>
```

Create `app/views/docs/pages/_workspaces_and_access.html.erb`:

```erb
<h1>Workspaces & access</h1>

<h2>Workspaces and projects</h2>

<p>
  A <strong>workspace</strong> is a team: it has members, roles, and settings. Inside a workspace,
  <strong>projects</strong> separate sending concerns — each project has its own sources, domains,
  API keys, templates, suppression list, and activity. One workspace per team and one project per
  application is the usual shape. You can belong to several workspaces and switch between them from
  the header.
</p>

<h2>Roles</h2>

<p>Each member has one role in the workspace:</p>

<table>
  <thead>
    <tr><th>Role</th><th>What it can do</th></tr>
  </thead>
  <tbody>
    <tr><td><code>owner</code></td><td>Everything, including workspace settings, members, and the audit log</td></tr>
    <tr><td><code>member</code></td><td>Day-to-day use of every sending feature</td></tr>
    <tr><td><code>sender</code></td><td>Send and inspect email only</td></tr>
    <tr><td><code>api_keys</code></td><td>Manage API keys</td></tr>
    <tr><td><code>domains</code></td><td>Manage domains and sources</td></tr>
    <tr><td><code>read_only</code></td><td>Look, don't touch</td></tr>
  </tbody>
</table>

<p>Every mutating action in the dashboard is checked against the member's role.</p>

<h2>Invitations</h2>

<p>
  Invite teammates by email from the workspace settings. The invitation link signs them up (or signs
  them in) and adds them to the workspace with the role you chose — this works even when open
  registration is off.
</p>

<h2>Audit log</h2>

<p>
  Security-relevant actions — issuing, revoking, or rotating API keys, and similar — are recorded in
  the workspace audit log with who did what, from where, and when.
</p>
```

Create `app/views/docs/pages/_account_security.html.erb`:

```erb
<h1>Account security</h1>

<h2>Registration</h2>

<p>
  Registration is open only for the very first user — whoever brings the instance up becomes its
  first workspace owner. After that, new people join by invitation. To open registration up (for
  example on a shared internal instance), set the <code>OPEN_REGISTRATION</code> environment
  variable.
</p>

<h2>Two-factor authentication</h2>

<p>
  Enable two-factor authentication from the <strong>Security</strong> section: scan the QR code with
  any TOTP app (1Password, Google Authenticator, …) and confirm with a code. You'll get a set of
  single-use recovery codes — store them somewhere safe; each one can stand in for a TOTP code once,
  and you can regenerate the set at any time. A workspace can also <em>require</em> two-factor for
  all of its members; anyone without it is prompted to enroll before they can continue.
</p>

<h2>Sessions</h2>

<p>
  <strong>Security</strong> also lists your active sessions with device and IP details. You can sign
  out everywhere else in one click — useful after using a shared machine. Password resets go through
  the usual email flow and sign out all existing sessions.
</p>
```

- [ ] **Step 4: Fact-check pass**

Re-read `app/models/workspace/roles.rb` and confirm the six role names and their capabilities as
rendered in the table; re-read `app/models/suppression.rb` for expiry/reactivation semantics; adjust
copy to match the code wherever they differ. The code is the source of truth, not this plan.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/models/docs/page_test.rb test/controllers/docs_controller_test.rb test/integration/docs_links_test.rb`
Expected: PASS

- [ ] **Step 6: Verify visually, run the suite, commit**

Run: `bin/rails test && bin/rubocop`
Expected: green

```bash
git add app/models/docs/page.rb app/views/docs/pages
git commit -m "docs: dashboard guide pages"
```

---

### Task 5: Self-hosting pages + slim the ops runbooks

Content sources: `docs/ops/first-deploy.md`, `docs/ops/monitoring.md`, `docs/ops/backup-and-restore.md`, `config/deploy.yml`, `bin/backup`. The in-app pages are the **generalized** versions (any self-hoster, no personal specifics — no `jorgegorka`, no "Jorge's email"); the repo runbooks then shrink to operator-specific notes pointing at the docs.

**Files:**
- Modify: `app/models/docs/page.rb` (add five entries)
- Create: `app/views/docs/pages/_self_hosting_quickstart.html.erb`
- Create: `app/views/docs/pages/_deployment.html.erb`
- Create: `app/views/docs/pages/_monitoring.html.erb`
- Create: `app/views/docs/pages/_backup_and_restore.html.erb`
- Create: `app/views/docs/pages/_configuration.html.erb`
- Modify: `docs/ops/first-deploy.md`, `docs/ops/monitoring.md`, `docs/ops/backup-and-restore.md`

**Interfaces:**
- Consumes: registry + tests; `ses-sns-ingestion`, `account-security`, `sources` pages for cross-links.
- Produces: slugs `self-hosting-quickstart`, `deployment`, `monitoring`, `backup-and-restore`, `configuration`. Task 8's README changes link `self-hosting-quickstart`.

- [ ] **Step 1: Register the pages (failing test)**

In `app/models/docs/page.rb`, append to `PAGES`:

```ruby
Entry.new(slug: "self-hosting-quickstart", title: "Self-hosting quickstart", section: "Getting started"),
Entry.new(slug: "deployment", title: "Deployment", section: "Self-hosting & operations"),
Entry.new(slug: "monitoring", title: "Monitoring", section: "Self-hosting & operations"),
Entry.new(slug: "backup-and-restore", title: "Backup & restore", section: "Self-hosting & operations"),
Entry.new(slug: "configuration", title: "Configuration", section: "Self-hosting & operations")
```

Run: `bin/rails test test/models/docs/page_test.rb`
Expected: FAIL — five missing templates

- [ ] **Step 2: Write the five page partials**

Create `app/views/docs/pages/_self_hosting_quickstart.html.erb`:

```erb
<h1>Self-hosting quickstart</h1>

<p>
  Departures runs as a single Rails app plus a job worker — SQLite for storage, no Redis, no Node.
  This page takes you from an empty server to your first delivered email. The short version: deploy
  with Kamal, register, and let onboarding walk you through connecting SES.
</p>

<h2>What you need</h2>

<ul>
  <li>A server (any VPS works) with Docker installed and ports 80 and 443 open.</li>
  <li>A domain for the app, with an A record pointing at the server — Kamal's proxy uses it to obtain
    a Let's Encrypt certificate automatically.</li>
  <li>A container registry to push the image to (GitHub Container Registry, Docker Hub, …).</li>
  <li>An AWS account with SES access in your region. If the account is new, SES starts in sandbox
    mode — request production access early, approval can take a day.</li>
</ul>

<h2>Deploy</h2>

<ol>
  <li>Clone the repository and fill in <code>config/deploy.yml</code>: your server's IP (web and job
    roles), your app domain (<code>proxy.host</code>), and your registry image name. Set the same
    domain as the mailer host in <code>config/environments/production.rb</code>.</li>
  <li>Create <code>.kamal/secrets</code> (git-ignored) forwarding your registry credential and the
    Rails master key — see <%= link_to "Deployment", doc_path("deployment") %> for the exact
    contents.</li>
  <li>Run <code>bin/kamal setup</code>. The image builds, pushes, and the web and job containers come
    up behind kamal-proxy with TLS.</li>
</ol>

<h2>First run</h2>

<ol>
  <li>Open the app and register — registration is open only for this first user, who becomes the
    workspace owner (see <%= link_to "Account security", doc_path("account-security") %>).</li>
  <li>Follow the onboarding checklist: add a <%= link_to "source", doc_path("sources") %>, verify a
    domain, issue an API key, send a test email.</li>
  <li>Wire delivery events back from SES —
    <%= link_to "SES event ingestion", doc_path("ses-sns-ingestion") %> — so statuses, bounces, and
    suppressions flow into the dashboard.</li>
</ol>

<p>
  Then set up <%= link_to "monitoring", doc_path("monitoring") %> and
  <%= link_to "backups", doc_path("backup-and-restore") %> — twenty minutes now, saved weekends later.
</p>
```

Create `app/views/docs/pages/_deployment.html.erb`:

```erb
<h1>Deployment</h1>

<p>
  Departures deploys with <a href="https://kamal-deploy.org">Kamal</a>: one <code>web</code> container
  and one <code>job</code> container (Solid Queue) behind kamal-proxy, which terminates TLS with an
  automatic Let's Encrypt certificate. State lives in a persistent Docker volume — the SQLite
  databases and the archived <code>.eml</code> files.
</p>

<h2>Configuration</h2>

<p>In <code>config/deploy.yml</code>, set:</p>

<ul>
  <li><code>image</code> — where to push, e.g. <code>ghcr.io/your-org/departures</code>.</li>
  <li>the server IP under both the <code>web</code> and <code>job</code> roles.</li>
  <li><code>proxy.host</code> — your app domain (must already resolve to the server, or the
    certificate request fails).</li>
</ul>

<p>
  Set the same domain as the mailer host in <code>config/environments/production.rb</code>
  (<code>config.action_mailer.default_url_options</code>) so links in transactional mail resolve.
</p>

<p><code>.kamal/secrets</code> (git-ignored — never commit it) forwards two values:</p>

<pre><code>KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD
RAILS_MASTER_KEY=$(cat config/master.key)</code></pre>

<p>
  Export a registry credential with push access (for GitHub Container Registry, a PAT with
  <code>write:packages</code>) as <code>KAMAL_REGISTRY_PASSWORD</code> before deploying.
</p>

<h2>First deploy and updates</h2>

<pre><code>bin/kamal setup    # first time: provisions the proxy and boots everything
bin/kamal deploy   # every deploy after that</code></pre>

<h2>Verifying a fresh deploy</h2>

<ul>
  <li><code>https://your-domain/up</code> returns <code>200</code> with a valid certificate.</li>
  <li>Plain <code>http://</code> redirects to <code>https://</code>, and responses carry
    <code>Strict-Transport-Security</code> and <code>Content-Security-Policy</code> headers.</li>
  <li><code>bin/kamal logs -r job</code> shows Solid Queue polling.</li>
  <li>A real send arrives in a real inbox, and after
    <%= link_to "SNS wiring", doc_path("ses-sns-ingestion") %>, its delivery event advances the
    status live in the dashboard.</li>
</ul>

<h2>Useful commands</h2>

<pre><code>bin/kamal logs           # web logs
bin/kamal logs -r job    # worker logs
bin/kamal console        # production Rails console
bin/kamal app stop       # stop the app (e.g. before a restore)
bin/kamal app boot       # start it again</code></pre>
```

Create `app/views/docs/pages/_monitoring.html.erb`:

```erb
<h1>Monitoring</h1>

<h2>Uptime</h2>

<p>
  Point an external uptime monitor (UptimeRobot's free tier is fine) at
  <code>https://your-domain/up</code> every few minutes. The endpoint returns <code>200</code> once
  the app boots. Note what it does and doesn't prove: it exercises the web process, not the
  databases or the job worker — the true end-to-end probe is a real send.
</p>

<h2>Error alerts</h2>

<p>
  Departures emails you when an unhandled exception occurs in a request or a background job — at most
  one email per error class every 10 minutes. Alerts are sent through a <em>dedicated</em> set of SES
  credentials so that a problem in your main sending path can't silence its own alarm. Configure them
  in Rails credentials (<code>bin/rails credentials:edit</code>); if the block is absent, the
  notifier is silent:
</p>

<pre><code>ops:
  aws_access_key_id: &lt;IAM key allowed only ses:SendRawEmail&gt;
  aws_secret_access_key: &lt;secret&gt;
  region: &lt;SES region&gt;
  from: &lt;verified sender, e.g. alerts@your-domain&gt;
  to: &lt;where alerts should go&gt;</code></pre>

<p>
  Known trade-off: a total SES outage also silences alerts — the independent uptime monitor above is
  the backstop.
</p>

<h2>When something looks wrong</h2>

<ul>
  <li><code>bin/kamal logs</code> and <code>bin/kamal logs -r job</code> — app and worker logs.</li>
  <li><code>bin/kamal console</code> — a production Rails console.</li>
  <li>The dashboard itself — the activity feed and an email's event timeline usually answer
    "did it send, and what did the recipient's server say?" faster than logs.</li>
</ul>
```

Create `app/views/docs/pages/_backup_and_restore.html.erb`:

```erb
<h1>Backup & restore</h1>

<p>
  Everything that matters lives in the persistent volume: the SQLite databases and the archived
  <code>.eml</code> files. The repo ships <code>bin/backup</code>, which snapshots all of it nightly
  to S3-compatible object storage via rclone, with 30-day retention. Recovery point: up to 24 hours.
</p>

<h2>One-time setup (on the host)</h2>

<ol>
  <li>Install the tools: <code>apt-get install -y sqlite3 rclone</code>.</li>
  <li><code>rclone config</code> — create a remote pointing at your S3-compatible provider, and
    create a bucket for the snapshots.</li>
  <li>Copy the script to the host:
    <code>scp bin/backup root@your-server:/usr/local/bin/departures-backup</code>
    (re-copy whenever <code>bin/backup</code> changes — it's versioned in the repo, executed on the
    host).</li>
  <li>Schedule it (<code>crontab -e</code> as root):
    <pre><code>15 3 * * * /usr/local/bin/departures-backup &gt;&gt; /var/log/departures-backup.log 2&gt;&amp;1</code></pre></li>
  <li>Run it once by hand and confirm the snapshot exists with <code>rclone ls</code>.</li>
</ol>

<p>
  <strong>Warning:</strong> the backup destination must be a dedicated bucket or prefix used only for
  these snapshots — the retention prune recursively deletes everything older than 30 days under that
  path.
</p>

<h2>Restoring</h2>

<ol>
  <li>Download a snapshot: <code>rclone copy &lt;remote&gt;:&lt;bucket&gt;/&lt;DATE&gt; /root/restore/&lt;DATE&gt;</code>.</li>
  <li>Check integrity <em>before</em> touching production:
    <code>sqlite3 production.sqlite3 "PRAGMA integrity_check;"</code> must print <code>ok</code>;
    spot-check a count, e.g. <code>"SELECT count(*) FROM emails;"</code>.</li>
  <li>Stop the app: <code>bin/kamal app stop</code>.</li>
  <li>On the host, swap the database files and unpack the <code>.eml</code> archive into the app's
    Docker volume (move the live files aside first, including any <code>-wal</code>/<code>-shm</code>
    siblings).</li>
  <li>Start the app: <code>bin/kamal app boot</code>, then verify <code>/up</code>, sign in, and open
    the activity page.</li>
</ol>

<p>
  The database snapshots are taken sequentially, seconds apart — after a restore, expect a handful of
  duplicate sends or orphaned jobs. Delivery is at-least-once by design, so the platform tolerates
  this. Run the download-and-integrity-check half of this as a drill now and then; a backup you've
  never restored is a hope, not a backup.
</p>
```

Create `app/views/docs/pages/_configuration.html.erb`:

```erb
<h1>Configuration</h1>

<h2>Environment variables</h2>

<table>
  <thead>
    <tr><th>Variable</th><th>Effect</th></tr>
  </thead>
  <tbody>
    <tr>
      <td><code>RAILS_MASTER_KEY</code></td>
      <td>Decrypts Rails credentials in production (the content of <code>config/master.key</code>).
        Forwarded to the container by Kamal via <code>.kamal/secrets</code>.</td>
    </tr>
    <tr>
      <td><code>OPEN_REGISTRATION</code></td>
      <td>When set, anyone can register. Otherwise registration is open only while the instance has
        no users; after that, teammates join by invitation.</td>
    </tr>
  </tbody>
</table>

<h2>Credentials</h2>

<p>
  Secrets live in encrypted Rails credentials (<code>bin/rails credentials:edit</code>). The one
  documented block is <code>ops:</code> for error-alert email — see
  <%= link_to "Monitoring", doc_path("monitoring") %>. SES credentials for <em>sending</em> are not
  configured here: they're entered per <%= link_to "source", doc_path("sources") %> in the dashboard
  and stored encrypted in the database.
</p>

<h2>Data retention</h2>

<p>
  Recurring jobs keep the database tidy: old emails and their archived <code>.eml</code> files,
  webhook delivery logs (30 days), expired idempotency keys, and expired invitations are pruned on
  schedule. Suppressions are kept — they're reputation-critical.
</p>
```

- [ ] **Step 3: Slim the ops runbooks**

Replace the **body** of each runbook with operator-specific notes plus a pointer. Keep any detail that is personal to this deployment; delete everything now covered in-app.

`docs/ops/first-deploy.md` becomes:

```markdown
# First deploy (operator notes)

The general runbook now lives in the app: **/docs/self-hosting-quickstart** and **/docs/deployment**.
This file keeps only what is specific to this deployment.

- Image: `ghcr.io/jorgegorka/departures` — registry PAT needs `write:packages`.
- Placeholders still to fill before first deploy: `<VPS_IP>`, `<APP_DOMAIN>` in `config/deploy.yml`
  and the mailer host in `config/environments/production.rb`.
- Phase 9 first-deploy verification: the 8-point checklist results should be recorded in the
  phase-close notes (see `docs/plans/departures-execution-plan.md` Phase 9 status).
```

`docs/ops/monitoring.md` becomes:

```markdown
# Monitoring (operator notes)

General guidance lives in the app: **/docs/monitoring**. Deployment-specific facts:

- Uptime: UptimeRobot free tier, HTTP monitor on `https://<APP_DOMAIN>/up`, alerts to Jorge's email.
- `ops:` credentials block — an IAM user restricted to `ses:SendRawEmail`, `to:` Jorge's address.
- Backup log on the host: `/var/log/departures-backup.log`.
```

`docs/ops/backup-and-restore.md` becomes:

```markdown
# Backup & restore (operator notes)

General setup and the restore procedure live in the app: **/docs/backup-and-restore**.
Deployment-specific facts:

- rclone remote and bucket are both named `departures-backups`.
- Volume path on the host: `/var/lib/docker/volumes/departures_storage/_data/`.
- Cron: `15 3 * * *` as root; log at `/var/log/departures-backup.log`.
- Restore drill: run download + `PRAGMA integrity_check` against last night's snapshot at each phase
  close and after any change to `bin/backup`; record the output in the phase-close notes.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/models/docs/page_test.rb test/controllers/docs_controller_test.rb test/integration/docs_links_test.rb`
Expected: PASS

- [ ] **Step 5: Verify visually, run the suite, commit**

Run: `bin/rails test && bin/rubocop`
Expected: green

```bash
git add app/models/docs/page.rb app/views/docs/pages docs/ops
git commit -m "docs: self-hosting pages; slim ops runbooks to operator notes"
```

---

### Task 6: Ruby gem page

Content source: `~/Sites/rails/departures-ruby/README.md` (adapt — it is already polished). Only this repo changes; the gem repo is untouched.

**Files:**
- Modify: `app/models/docs/page.rb` (add one entry)
- Create: `app/views/docs/pages/_ruby_gem.html.erb`
- Modify: `app/views/docs/pages/_getting_started.html.erb` (repoint the temporary self-link)

**Interfaces:**
- Consumes: registry + tests; `api-reference` page for cross-links.
- Produces: slug `ruby-gem`.

- [ ] **Step 1: Register the page (failing test)**

Append to `PAGES` in `app/models/docs/page.rb`:

```ruby
Entry.new(slug: "ruby-gem", title: "Ruby gem", section: "API reference")
```

Run: `bin/rails test test/models/docs/page_test.rb`
Expected: FAIL — missing template

- [ ] **Step 2: Write the page and repoint the getting-started link**

Create `app/views/docs/pages/_ruby_gem.html.erb`:

```erb
<h1>Ruby gem</h1>

<p>
  <code>departures-ruby</code> is the official Ruby client: a drop-in Action Mailer delivery method
  for Rails apps, and a plain HTTP client for everything else. It has zero runtime dependencies.
</p>

<pre><code># Gemfile
gem "departures-ruby"</code></pre>

<h2>Rails: Action Mailer</h2>

<p>Point Action Mailer at your Departures instance and every existing mailer just works:</p>

<pre><code># config/environments/production.rb
config.action_mailer.delivery_method = :departures
config.action_mailer.departures_settings = {
  api_key: Rails.application.credentials.dig(:departures, :api_key),
  base_url: "https://your-departures-host"
}</code></pre>

<p>
  The delivery method maps the whole <code>Mail::Message</code> — from/to/cc/bcc, subject, HTML and
  text parts, attachments, custom <code>X-</code> headers — onto the API, and writes the returned id
  back into the message as <code>X-Departures-Id</code> so your logs can reference the dashboard
  record.
</p>

<h2>Plain client</h2>

<pre><code>client = Departures::Client.new(api_key: ENV["DEPARTURES_API_KEY"], base_url: "https://your-departures-host")

client.send_email(
  from: "hello@example.com",
  to: ["user@example.com"],
  subject: "Welcome",
  html: "&lt;p&gt;Hi there&lt;/p&gt;",
  idempotency_key: "welcome-user-42"
)

client.list_emails</code></pre>

<p>
  <code>send_email</code> accepts every parameter the <%= link_to "API", doc_path("api-reference") %>
  does, including <code>template_id:</code> and <code>variables:</code> for template sends and
  <code>environment:</code> for selecting a source.
</p>

<h2>Errors and retries</h2>

<table>
  <thead>
    <tr><th>Error</th><th>Raised on</th></tr>
  </thead>
  <tbody>
    <tr><td><code>Departures::ConnectionError</code></td><td>Network failure or timeout</td></tr>
    <tr><td><code>Departures::AuthenticationError</code></td><td>401 / 403</td></tr>
    <tr><td><code>Departures::RateLimitedError</code></td><td>429</td></tr>
    <tr><td><code>Departures::SuppressedRecipientsError</code></td><td>422 for suppressed recipients</td></tr>
    <tr><td><code>Departures::ApiError</code></td><td>Any other non-2xx (carries <code>#status</code> and <code>#errors</code>)</td></tr>
  </tbody>
</table>

<p>
  The gem deliberately never retries — your job layer is the right place for retry policy
  (<code>retry_on Departures::ConnectionError</code>, for example), paired with an idempotency key so
  retries can't double-send.
</p>
```

In `app/views/docs/pages/_getting_started.html.erb`, change
`<%= link_to "Ruby gem", doc_path("getting-started") %>` to
`<%= link_to "Ruby gem", doc_path("ruby-gem") %>`.

- [ ] **Step 3: Run the tests, verify visually, commit**

Run: `bin/rails test && bin/rubocop`
Expected: green

```bash
git add app/models/docs/page.rb app/views/docs/pages
git commit -m "docs: ruby gem page"
```

---

### Task 7: Cross-linking — helper, header link, contextual links

**Files:**
- Create: `app/helpers/docs_helper.rb`
- Modify: `app/views/layouts/application.html.erb` (Docs link in `shell-header__actions`)
- Modify: `app/views/onboardings/show.html.erb` (one link per step)
- Modify: the index/landing view of each dashboard section (one line each; exact insertion point may vary — put it inside the page's intro/header area, after the `<h1>`): `app/views/sources/index.html.erb`, `app/views/domains/index.html.erb`, `app/views/templates/index.html.erb`, `app/views/suppressions/index.html.erb`, `app/views/bounces/index.html.erb`, `app/views/webhook_endpoints/index.html.erb`, `app/views/api_keys/index.html.erb`, `app/views/activity/show.html.erb`
- Test: `test/helpers/docs_helper_test.rb`

**Interfaces:**
- Consumes: every slug registered in Tasks 1–6.
- Produces: `docs_link_to(text, slug, **options)` — raises `ActiveRecord::RecordNotFound` at render time for a typo'd slug, so a broken contextual link fails tests instead of shipping.

- [ ] **Step 1: Write the failing helper test**

Create `test/helpers/docs_helper_test.rb`:

```ruby
require "test_helper"

class DocsHelperTest < ActionView::TestCase
  test "docs_link_to links to the registered page" do
    html = docs_link_to("Learn more", "getting-started")

    assert_includes html, doc_path("getting-started")
    assert_includes html, "Learn more"
  end

  test "docs_link_to raises for an unregistered slug" do
    assert_raises(ActiveRecord::RecordNotFound) { docs_link_to("Learn more", "nope") }
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/helpers/docs_helper_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'docs_link_to'`

- [ ] **Step 3: Implement the helper**

Create `app/helpers/docs_helper.rb`:

```ruby
module DocsHelper
  def docs_link_to(text, slug, **options)
    link_to text, doc_path(Docs::Page.find(slug)), **options
  end
end
```

- [ ] **Step 4: Run the helper test to verify it passes**

Run: `bin/rails test test/helpers/docs_helper_test.rb`
Expected: PASS

- [ ] **Step 5: Add the header and contextual links**

**Header** — in `app/views/layouts/application.html.erb`, inside `<div class="shell-header__actions">`, before the workspace switcher (re-read the file first; it is under active redesign):

```erb
<%= link_to "Docs", docs_path, class: "btn btn--plain" %>
```

**Onboarding** — in `app/views/onboardings/show.html.erb`, append a docs link to each step's description paragraph:

- Source step: `<%= docs_link_to "Learn about sources", "sources" %>`
- Domain step: `<%= docs_link_to "Learn about domain verification", "domains-and-dkim" %>`
- API key step: `<%= docs_link_to "Learn about API keys", "api-keys" %>`
- Test email step: `<%= docs_link_to "Learn about sending", "sending-and-templates" %>`

**Section indexes** — one line each, inside the intro/header area after the `<h1>` (match each view's existing markup):

| View | Line |
|---|---|
| `sources/index` | `<%= docs_link_to "Learn more about sources", "sources" %>` |
| `domains/index` | `<%= docs_link_to "Learn more about domains & DKIM", "domains-and-dkim" %>` |
| `templates/index` | `<%= docs_link_to "Learn more about templates", "sending-and-templates" %>` |
| `suppressions/index` | `<%= docs_link_to "Learn more about suppressions", "suppressions-and-bounces" %>` |
| `bounces/index` | `<%= docs_link_to "Learn more about bounces", "suppressions-and-bounces" %>` |
| `webhook_endpoints/index` | `<%= docs_link_to "Learn more about webhooks", "outbound-webhooks" %>` |
| `api_keys/index` | `<%= docs_link_to "Learn more about API keys", "api-keys" %>` |
| `activity/show` | `<%= docs_link_to "Learn more about activity", "activity-and-inspecting-email" %>` |

- [ ] **Step 6: Run the full suite (existing controller tests cover these views), verify visually, commit**

Run: `bin/rails test && bin/rubocop`
Expected: green — every touched view renders under its existing controller tests, and `docs_link_to` raises on any typo'd slug.

Spot-check in the browser: header Docs link on the dashboard, one contextual link per section, all four onboarding links (temporarily un-onboard via console if needed, or view as a fresh user).

```bash
git add app/helpers/docs_helper.rb app/views test/helpers/docs_helper_test.rb
git commit -m "feat: docs helper, header Docs link, contextual Learn-more links"
```

---

### Task 8: README, execution plan, wrap-up

**Files:**
- Modify: `README.md`
- Modify: `docs/plans/departures-execution-plan.md`

**Interfaces:**
- Consumes: slug `self-hosting-quickstart` (Task 5) and the `/docs` section as a whole.

- [ ] **Step 1: Update the README**

1. Replace line 101 — `Detailed setup (AWS credentials, SNS topic wiring, deployment) will be documented as the corresponding features land.` — with:

```markdown
Full documentation — dashboard guides, API reference, webhooks, and self-hosting — is built into the
app at `/docs` (no account needed). For production setup start with `/docs/self-hosting-quickstart`.
```

2. Add a `## Documentation` section right after `## How it works`:

```markdown
## Documentation

Departures documents itself: every instance serves its own docs at **`/docs`** — publicly, versioned
with the code it describes. Guides for every dashboard feature, the full API reference, webhook
signature verification, and self-hosting runbooks (deployment, monitoring, backup & restore).

The official Ruby client is [`departures-ruby`](https://github.com/jorgegorka/departures-ruby): a
drop-in Action Mailer delivery method plus a plain HTTP client.
```

(Verify the gem's GitHub URL before committing — if the repository isn't published yet, reference it as "the companion `departures-ruby` gem" without a link.)

3. In the `> **Status:**` banner (line 7), replace the "target scope" wording with a statement that the platform is feature-complete and self-documenting, e.g.:

```markdown
> **Status:** Feature-complete through production readiness (phases 0–9) plus in-app documentation.
> See `docs/plans/departures-execution-plan.md` for the build history.
```

- [ ] **Step 2: Update the execution plan**

In `docs/plans/departures-execution-plan.md`, Section B, after the Phase 9 block, add:

```markdown
### Phase 10 — Documentation (complete)

Detailed plan: **`docs/plans/phase-10-documentation-plan.md`**.

Delivered: public in-app docs at `/docs` — a `Docs::Page` plain-Ruby registry driving routes,
sidebar, landing page, and table-driven tests; 18 hand-written ERB pages across 5 sections (getting
started, dashboard guides, API reference, webhooks, self-hosting & operations); dedicated `docs`
layout + `docs.css` on the token system; `docs_link_to` helper with header Docs link and contextual
Learn-more links across the dashboard and onboarding; README documentation section; `docs/ops/*`
slimmed to operator notes. OpenAPI spec deliberately deferred (hand-maintained spec would drift; no
gem to serve/validate one) — candidate for a future phase.
```

- [ ] **Step 3: Final verification**

Run: `bin/rails test && bin/rubocop`
Expected: green

Full manual pass: `/docs` logged out in light + dark; every sidebar page; `/docs/bogus` → 404; signed-in unonboarded user can read docs; header Docs link; contextual links.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/plans/departures-execution-plan.md
git commit -m "docs: README documentation section; execution plan phase 10 status"
```

---

## Verification (phase close)

- `bin/rails test` and `bin/rubocop` green.
- Automated: the table-driven controller test renders every registered page anonymously; the model test pins every registry entry to a template on disk; the link-integrity test crawls every page and validates every internal `/docs` link; `docs_link_to` raises on unregistered slugs under the existing view tests.
- Manual: full click-through of the sidebar in both themes; 404 on unknown slugs; onboarding links as an unonboarded user; keyboard-only navigation of the sidebar (visible focus states, WCAG 2.1 AA).

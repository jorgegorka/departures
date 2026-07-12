# Demo data for developing and visually testing the dashboard: metrics with
# previous-period deltas, sparklines, activity/bounce lists at their query
# limits, suppression/webhook/audit views, empty states, and the workspace
# switcher. Idempotent: structural records are find_or_create'd and email
# volume only tops up to its target, so `db:seed` can run repeatedly and
# `db:seed:replant` rebuilds from scratch.
#
# Sign in with demo@departures.test / password (see summary printed at the end).

return if Rails.env.production?

RNG = Random.new(20_260_712)

FIRST_NAMES = %w[ alice bruno carmen diego elena felix greta hugo irene joel karla liam
                  maria nadia oscar paula quinn rosa samir tania ulises vera wanda ]
CUSTOMER_DOMAINS = %w[ heyfast.io lumina.app nortech.es papeleo.dev brightmail.com
                       zenlayer.co altavista.dev correo-tester.net ]

def customer_address(rng)
  "#{FIRST_NAMES.sample(random: rng)}#{rng.rand(1..99)}@#{CUSTOMER_DOMAINS.sample(random: rng)}"
end

def weighted_sample(rng, weights)
  point = rng.rand(weights.values.sum)
  weights.each do |key, weight|
    return key if point < weight
    point -= weight
  end
  weights.keys.last
end

# Recent-biased timestamp inside the last `days` days, so 24h/7d/30d ranges
# all have data and the sparkline slopes upward.
def moment_within(rng, days)
  offset_days = (rng.rand**2) * days
  Time.current - offset_days.days - rng.rand(0..86_399).seconds
end

def find_or_create_user(email, password: "password")
  User.find_or_create_by!(email_address: email) do |user|
    user.password = password
    user.password_confirmation = password
  end
end

# --- People -------------------------------------------------------------

demo  = find_or_create_user("demo@departures.test")
ana   = find_or_create_user("ana@departures.test")
leo   = find_or_create_user("leo@departures.test")
mia   = find_or_create_user("mia@departures.test")
sam   = find_or_create_user("sam@departures.test")
rocio = find_or_create_user("rocio@departures.test")

if demo.sessions.none?
  demo.sessions.create!(ip_address: "83.44.120.9", user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) Safari/605.1.15",
    last_active_at: 10.minutes.ago, created_at: 2.days.ago)
  demo.sessions.create!(ip_address: "83.44.120.9", user_agent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) Safari/604.1",
    last_active_at: 3.hours.ago, created_at: 6.days.ago)
end

# --- Workspaces ----------------------------------------------------------

acme = Workspace.find_or_create_by!(slug: "acme-studio") do |workspace|
  workspace.name = "Acme Studio"
  workspace.owner = demo
  workspace.onboarded_at = 60.days.ago
  workspace.setup_started_at = 61.days.ago
end

# Fresh workspace with nothing configured: exercises onboarding and empty states.
freelance = Workspace.find_or_create_by!(slug: "freelance-lab") do |workspace|
  workspace.name = "Freelance Lab"
  workspace.owner = demo
end

# Workspace owned by someone else where demo is a plain member: exercises the
# switcher and role-restricted navigation.
northwind = Workspace.find_or_create_by!(slug: "northwind") do |workspace|
  workspace.name = "Northwind"
  workspace.owner = ana
  workspace.onboarded_at = 20.days.ago
end

{ acme      => { demo => "owner", ana => "member", leo => "sender", mia => "read_only", sam => "api_keys", rocio => "domains" },
  freelance => { demo => "owner" },
  northwind => { ana => "owner", demo => "member" } }.each do |workspace, members|
  members.each do |user, role|
    workspace.memberships.find_or_create_by!(user: user) { |membership| membership.role = role }
  end
end

if acme.invitations.none?
  acme.invitations.create!(email: "nina@departures.test", role: "member", invited_by: demo)
  acme.invitations.create!(email: "old-invite@departures.test", role: "sender", invited_by: demo,
    expires_at: 3.days.ago, created_at: 10.days.ago)
  acme.invitations.create!(email: ana.email_address, role: "member", invited_by: demo,
    accepted_at: 55.days.ago, created_at: 58.days.ago)
end

# --- Projects, sources, domains, keys, templates -------------------------

transactional = acme.projects.find_or_create_by!(slug: "transactional") { |project| project.name = "Transactional" }
marketing     = acme.projects.find_or_create_by!(slug: "marketing")     { |project| project.name = "Marketing" }
acme.projects.find_or_create_by!(slug: "legacy-notifications") do |project|
  project.name = "Legacy Notifications"
  project.archived_at = 15.days.ago
end
freelance.projects.find_or_create_by!(slug: "portfolio") { |project| project.name = "Portfolio" }
northwind_app = northwind.projects.find_or_create_by!(slug: "app") { |project| project.name = "App" }

production_source = transactional.sources.find_or_create_by!(environment: "production") do |source|
  source.name = "SES eu-west-1"
  source.region = "eu-west-1"
  source.default_from = "Acme <no-reply@acmestudio.dev>"
  source.configuration_set = "departures-production"
  source.aws_access_key_id = "AKIA_DEMO_PRODUCTION"
  source.aws_secret_access_key = "demo-secret-not-real"
  source.last_quota_checked_at = 25.minutes.ago
  source.last_quota = { "max_24_hour_send" => 50_000, "max_send_rate" => 14.0,
    "sent_last_24_hours" => 3_182, "sending_enabled" => true, "production_access" => true }
end

staging_source = transactional.sources.find_or_create_by!(environment: "staging") do |source|
  source.name = "SES sandbox"
  source.region = "eu-west-1"
  source.default_from = "Acme Staging <staging@acmestudio.dev>"
  source.retention_days = 7
  source.aws_access_key_id = "AKIA_DEMO_STAGING"
  source.aws_secret_access_key = "demo-secret-not-real"
  source.last_quota_checked_at = 2.days.ago # stale, exercises the stale-quota UI
  source.last_quota = { "max_24_hour_send" => 200, "max_send_rate" => 1.0,
    "sent_last_24_hours" => 12, "sending_enabled" => true, "production_access" => false }
end

marketing_source = marketing.sources.find_or_create_by!(environment: "production") do |source|
  source.name = "SES us-east-1"
  source.region = "us-east-1"
  source.default_from = "Acme News <news@mail.acmestudio.dev>"
  source.aws_access_key_id = "AKIA_DEMO_MARKETING"
  source.aws_secret_access_key = "demo-secret-not-real"
  # No quota checked yet: exercises the "never checked" state.
end

northwind_source = northwind_app.sources.find_or_create_by!(environment: "production") do |source|
  source.name = "SES eu-central-1"
  source.region = "eu-central-1"
  source.default_from = "Northwind <hello@northwind.app>"
  source.aws_access_key_id = "AKIA_DEMO_NORTHWIND"
  source.aws_secret_access_key = "demo-secret-not-real"
end

fake_dkim = -> { Array.new(3) { SecureRandom.alphanumeric(32).downcase } }
transactional.domains.find_or_create_by!(name: "acmestudio.dev") do |domain|
  domain.status = "verified"
  domain.dkim_tokens = fake_dkim.call
  domain.last_checked_at = 40.minutes.ago
end
transactional.domains.find_or_create_by!(name: "updates.acmestudio.dev") do |domain|
  domain.status = "pending"
  domain.dkim_tokens = fake_dkim.call
  domain.last_checked_at = 2.hours.ago
end
transactional.domains.find_or_create_by!(name: "old-acme.com") do |domain|
  domain.status = "failed"
  domain.last_checked_at = 4.days.ago
end
marketing.domains.find_or_create_by!(name: "mail.acmestudio.dev") do |domain|
  domain.status = "verified"
  domain.dkim_tokens = fake_dkim.call
  domain.last_checked_at = 3.hours.ago
end
northwind_app.domains.find_or_create_by!(name: "northwind.app") do |domain|
  domain.status = "verified"
  domain.dkim_tokens = fake_dkim.call
  domain.last_checked_at = 1.hour.ago
end

if transactional.api_keys.none?
  live_key = ApiKey.issue(project: transactional, name: "Rails app", scopes: %w[ send read:activity ])
  live_key.update!(last_used_at: 4.minutes.ago, last_used_ip: "34.240.11.87",
    last_used_user_agent: "departures-ruby/1.2.0", created_at: 59.days.ago)

  ApiKey.issue(project: transactional, name: "Reporting cron", scopes: %w[ read:activity ], expires_in: 20.days)
    .update!(last_used_at: 1.day.ago, last_used_ip: "34.240.11.87", last_used_user_agent: "curl/8.6.0")

  ApiKey.issue(project: transactional, name: "Old deploy key", scopes: %w[ send ])
    .update!(revoked_at: 12.days.ago, created_at: 50.days.ago,
      last_used_at: 13.days.ago, last_used_ip: "54.170.2.31", last_used_user_agent: "departures-node/0.9.1")

  ApiKey.issue(project: transactional, name: "Expired trial key", scopes: %w[ send ])
    .update!(expires_at: 5.days.ago, created_at: 40.days.ago)

  ApiKey.issue(project: marketing, name: "Newsletter service", scopes: %w[ send ])
    .update!(last_used_at: 2.hours.ago, last_used_ip: "3.250.44.10", last_used_user_agent: "departures-python/0.4.2")

  ApiKey.issue(project: northwind_app, name: "Backend", scopes: %w[ send read:activity ])
end

{ "Welcome email"        => { slug: "welcome", subject: "Welcome to Acme, {{ name }}!" },
  "Password reset"       => { slug: "password-reset", subject: "Reset your Acme password" },
  "Invoice ready"        => { slug: "invoice-ready", subject: "Invoice {{ invoice_number }} is ready" },
  "Weekly digest"        => { slug: "weekly-digest", subject: "Your week at Acme" },
  "Trial ending soon"    => { slug: "trial-ending", subject: "{{ name }}, your trial ends in {{ days_left }} days" } }.each do |name, attrs|
  transactional.templates.find_or_create_by!(slug: attrs[:slug]) do |template|
    template.name = name
    template.subject = attrs[:subject]
    template.html_body = <<~HTML
      <h1>#{name}</h1>
      <p>Hi {{ name }},</p>
      <p>This is the #{name.downcase} template. You can manage your preferences at any time.</p>
      <p>— The Acme team</p>
    HTML
    template.text_body = "Hi {{ name }},\n\nThis is the #{name.downcase} template.\n\n— The Acme team"
  end
end

# --- Webhook endpoints ----------------------------------------------------

hooks_endpoint = transactional.webhook_endpoints.find_or_create_by!(url: "https://hooks.acmestudio.dev/departures") do |endpoint|
  endpoint.events = %w[ delivery bounce complaint open click ]
end
transactional.webhook_endpoints.find_or_create_by!(url: "https://ops.acmestudio.dev/email-events") do |endpoint|
  endpoint.events = %w[ bounce complaint ]
end
transactional.webhook_endpoints.find_or_create_by!(url: "https://legacy.acmestudio.dev/hooks") do |endpoint|
  endpoint.events = %w[ delivery ]
  endpoint.active = false
end

# --- Emails ---------------------------------------------------------------

SUBJECTS = [
  "Welcome to Acme, let's get you set up",
  "Reset your Acme password",
  "Invoice INV-%04d is ready",
  "Your export has finished",
  "Payment received — thank you",
  "Action required: confirm your email address",
  "Tu resumen semanal de Acme 📬",
  "New sign-in to your account from Madrid, Spain",
  "We couldn't process your payment",
  "Your trial ends in 3 days",
  "A very long subject line intended to test truncation behaviour in list views, table cells, tooltips and anywhere else a subject may appear in the interface",
  nil # no-subject edge case
].freeze

# status => the SES event chain that produced it
STATUS_EVENTS = {
  "queued"     => [],
  "sending"    => [],
  "sent"       => %w[ send ],
  "delivered"  => %w[ send delivery ],
  "opened"     => %w[ send delivery open ],
  "clicked"    => %w[ send delivery open click ],
  "bounced"    => %w[ send bounce ],
  "complained" => %w[ send delivery complaint ],
  "failed"     => %w[ send reject ]
}.freeze

STATUS_WEIGHTS = {
  "delivered" => 46, "opened" => 20, "clicked" => 9, "sent" => 6,
  "bounced" => 8, "complained" => 2, "failed" => 3, "queued" => 4, "sending" => 2
}.freeze

def seed_emails(project, source, target:, days: 35, rng: RNG)
  api_key = project.api_keys.first
  count_needed = target - project.emails.where(source: source).count
  return if count_needed <= 0

  from_pool = [ source.default_from, "Acme Billing <billing@acmestudio.dev>", "Acme Support <support@acmestudio.dev>" ]

  project.transaction do
    count_needed.times do |index|
      status = weighted_sample(rng, STATUS_WEIGHTS)
      # Queued/sending only make sense moments ago; settled statuses spread out.
      created_at = %w[ queued sending ].include?(status) ? rng.rand(1..30).minutes.ago : moment_within(rng, days)
      subject = SUBJECTS.sample(random: rng)
      subject %= rng.rand(1..9999) if subject&.include?("%04d")

      email = project.emails.create!(
        source: source, api_key: api_key, status: status,
        from: from_pool.sample(random: rng),
        subject: subject,
        text_body: "Hi,\n\nThis is a seeded demo email.\n\n— Acme",
        html_body: "<p>Hi,</p><p>This is a seeded demo email.</p><p>— Acme</p>",
        tags: { "campaign" => %w[ onboarding billing digest security ].sample(random: rng),
                "environment" => source.environment },
        headers: { "X-Demo" => "true" },
        ses_message_id: (status == "queued" ? nil : "010f#{SecureRandom.hex(24)}"),
        bounce_type: (status == "bounced" ? (rng.rand < 0.65 ? "permanent" : "transient") : nil),
        failure_reason: (status == "failed" ? "554 Message rejected: sending suspended for this identity" : nil),
        resent_at: (rng.rand < 0.03 ? created_at + 2.hours : nil),
        mime_size: rng.rand(3_000..180_000),
        created_at: created_at, updated_at: created_at)

      email.recipients.create!(address: customer_address(rng), kind: "to")
      email.recipients.create!(address: customer_address(rng), kind: "to") if rng.rand < 0.15
      email.recipients.create!(address: customer_address(rng), kind: "cc") if rng.rand < 0.10
      email.recipients.create!(address: "archive@acmestudio.dev", kind: "bcc") if rng.rand < 0.08

      if rng.rand < 0.06
        email.attachments.create!(filename: "invoice-#{rng.rand(1000..9999)}.pdf",
          content_type: "application/pdf", byte_size: rng.rand(20_000..400_000))
      end

      recipient = email.recipients.first.address
      STATUS_EVENTS.fetch(status).each_with_index do |event_type, event_index|
        email.events.create!(event_type: event_type, recipient: recipient,
          ses_message_id: email.ses_message_id,
          occurred_at: created_at + (event_index * rng.rand(30..900)).seconds,
          url: (event_type == "click" ? "https://acmestudio.dev/app/invoices" : nil),
          user_agent: (%w[ open click ].include?(event_type) ? "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X)" : nil),
          ip: (%w[ open click ].include?(event_type) ? "88.12.#{rng.rand(1..254)}.#{rng.rand(1..254)}" : nil),
          payload: (event_type == "bounce" ? { "bounceType" => email.bounce_type&.capitalize } : {}))
      end
    end
  end
end

# 420 emails: fills the activity list past its 100-row limit, feeds all three
# metric ranges plus their previous-period deltas, and keeps bounces/suppressions
# realistic. Marketing and Northwind get smaller volumes for contrast.
seed_emails(transactional, production_source, target: 420)
seed_emails(transactional, staging_source, target: 20, days: 7)
seed_emails(marketing, marketing_source, target: 60, days: 30)
seed_emails(northwind_app, northwind_source, target: 25, days: 14)

# --- Suppressions ---------------------------------------------------------

if transactional.suppressions.none?
  suppressed = Set.new

  bounced_addresses = transactional.emails.hard_bounced.joins(:recipients)
    .pluck("email_recipients.address").uniq.first(8)
  bounced_addresses.each_with_index do |address, index|
    next unless suppressed.add?(address)
    transactional.suppressions.create!(email: address, reason: "bounce", created_at: (index + 1).days.ago)
  end

  complained_addresses = transactional.emails.complained.joins(:recipients)
    .pluck("email_recipients.address").uniq.first(4)
  complained_addresses.each_with_index do |address, index|
    next unless suppressed.add?(address)
    transactional.suppressions.create!(email: address, reason: "complaint", created_at: (index + 2).days.ago)
  end

  transactional.suppressions.create!(email: "cliente-enfadado@papeleo.dev", reason: "manual", created_at: 9.days.ago)
  transactional.suppressions.create!(email: "temporal@lumina.app", reason: "manual",
    expires_at: 10.days.from_now, created_at: 3.days.ago)
  transactional.suppressions.create!(email: "expired-block@nortech.es", reason: "manual",
    expires_at: 2.days.ago, created_at: 30.days.ago)
end

# --- Webhook deliveries and SNS logs ---------------------------------------

if hooks_endpoint.deliveries.none?
  delivery_emails = transactional.emails.where(status: %w[ delivered opened clicked bounced complained ]).limit(120)
  delivery_emails.each do |email|
    outcome = weighted_sample(RNG, "succeeded" => 82, "failed" => 12, "pending" => 6)
    attempts = outcome == "failed" ? RNG.rand(1..5) : (outcome == "pending" ? 0 : 1)
    hooks_endpoint.deliveries.create!(
      email: email, event_type: STATUS_EVENTS.fetch(email.status).last,
      status: outcome, attempts: attempts,
      http_status: { "succeeded" => 200, "failed" => [ 500, 502, 404 ].sample(random: RNG), "pending" => nil }.fetch(outcome),
      latency_ms: (outcome == "pending" ? nil : RNG.rand(40..2_400)),
      response_body: (outcome == "failed" ? "upstream timeout" : (outcome == "succeeded" ? "ok" : nil)),
      last_attempted_at: (outcome == "pending" ? nil : email.created_at + 5.minutes),
      payload: { "event" => STATUS_EVENTS.fetch(email.status).last, "email_id" => email.public_id },
      created_at: email.created_at + 4.minutes, updated_at: email.created_at + 5.minutes)
  end
end

if production_source.webhook_logs.none?
  40.times do
    status = weighted_sample(RNG, "processed" => 30, "unmatched" => 5, "failed" => 3, "received" => 2)
    created_at = moment_within(RNG, 14)
    production_source.webhook_logs.create!(
      message_type: "Notification", status: status,
      payload: { "Type" => "Notification", "MessageId" => SecureRandom.uuid,
                 "Message" => { "eventType" => %w[ Delivery Bounce Open Click ].sample(random: RNG) }.to_json },
      processed_at: (status == "received" ? nil : created_at + 2.seconds),
      error: (status == "failed" ? "unexpected token at 'not-json'" : nil),
      created_at: created_at, updated_at: created_at)
  end
  production_source.webhook_logs.create!(message_type: "SubscriptionConfirmation", status: "processed",
    payload: { "Type" => "SubscriptionConfirmation", "MessageId" => SecureRandom.uuid },
    processed_at: 59.days.ago, created_at: 59.days.ago, updated_at: 59.days.ago)
end

# --- Audit trail ------------------------------------------------------------

if acme.audit_events.where.not(action: [ "api_key.issued", "api_key.revoked" ]).none?
  members = [ demo, ana, leo ]
  [ [ "domain.created", { name: "acmestudio.dev" } ],
    [ "domain.verified", { name: "acmestudio.dev" } ],
    [ "domain.created", { name: "updates.acmestudio.dev" } ],
    [ "source.created", { environment: "production" } ],
    [ "source.updated", { environment: "staging" } ],
    [ "webhook_endpoint.created", { url: "https://hooks.acmestudio.dev/departures" } ],
    [ "webhook_endpoint.updated", { url: "https://legacy.acmestudio.dev/hooks" } ],
    [ "invitation.created", { email: "nina@departures.test", role: "member" } ],
    [ "invitation.accepted", { email: ana.email_address, role: "member" } ],
    [ "suppression.created", { email: "cliente-enfadado@papeleo.dev" } ],
    [ "suppression.destroyed", { email: "expired-block@nortech.es" } ],
    [ "two_factor.enabled", {} ],
    [ "session.revoked", {} ] ].each do |action, metadata|
    AuditEvent.create!(action: action, metadata: metadata, workspace: acme,
      user: members.sample(random: RNG), ip: "83.44.120.9", created_at: moment_within(RNG, 60))
  end
end

puts <<~SUMMARY

  Seeded demo data:
    Sign in as demo@departures.test / password (owner of Acme Studio + Freelance Lab, member of Northwind)
    Other users: ana, leo, mia, sam, rocio @departures.test (password "password")

    Acme Studio  · Transactional: #{transactional.emails.count} emails, #{transactional.suppressions.count} suppressions,
                   #{transactional.api_keys.count} API keys, #{transactional.domains.count} domains, #{transactional.webhook_endpoints.count} webhook endpoints
                 · Marketing: #{marketing.emails.count} emails · Legacy Notifications: archived
    Freelance Lab · empty workspace for onboarding/empty states
    Northwind     · demo is a plain member (role-restricted views)
SUMMARY

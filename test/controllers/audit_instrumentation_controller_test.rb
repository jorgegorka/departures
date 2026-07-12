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

  test "domain create and destroy are audited" do
    post domains_path, params: { domain: { name: "audit-example.com" } }
    assert AuditEvent.exists?(action: "domain.created"), "expected a domain.created audit event"

    delete domain_path(domains(:acme_com))
    assert AuditEvent.exists?(action: "domain.destroyed"), "expected a domain.destroyed audit event"
  end

  test "creating a source is audited" do
    post sources_path, params: { source: { name: "Audit source", environment: "staging",
      region: "eu-west-1", aws_access_key_id: "AKIAAUDIT", aws_secret_access_key: "audit-secret" } }

    source = Source.find_by!(name: "Audit source")
    assert AuditEvent.exists?(action: "source.created", subject: source)
  end

  test "webhook endpoint create and update are audited" do
    post webhook_endpoints_path, params: { webhook_endpoint: { url: "https://hooks.example.com/audit",
      events: [ "bounce" ], active: true } }
    endpoint = WebhookEndpoint.find_by!(url: "https://hooks.example.com/audit")
    assert AuditEvent.exists?(action: "webhook_endpoint.created", subject: endpoint)

    patch webhook_endpoint_path(webhook_endpoints(:acme_all)),
      params: { webhook_endpoint: { url: "https://hooks.acme.com/renamed" } }
    assert AuditEvent.exists?(action: "webhook_endpoint.updated", subject: webhook_endpoints(:acme_all))
  end
end

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

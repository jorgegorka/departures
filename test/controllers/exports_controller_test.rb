require "test_helper"

class ExportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
  end

  test "emails export streams project-scoped CSV" do
    get export_url("emails")

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_includes response.body, "public_id,status,from,subject"
    assert_includes response.body, emails(:acme_delivered).public_id
    assert_not_includes response.body, emails(:globex_delivered).public_id
  end

  test "bounces export only includes bounced emails" do
    get export_url("bounces")

    assert_includes response.body, emails(:acme_hard_bounce).public_id
    assert_not_includes response.body, emails(:acme_delivered).public_id
  end

  test "suppressions export includes address and reason" do
    get export_url("suppressions")

    assert_includes response.body, "blocked@example.com"
    assert_includes response.body, "complaint"
  end

  test "exports neutralize spreadsheet formula prefixes" do
    emails(:acme_delivered).update_columns(subject: "=HYPERLINK(\"https://evil.example\",\"x\")")
    get export_url("emails")
    assert_includes response.body, "'=HYPERLINK"

    Suppression.record(projects(:acme_default), "safe@example.com", reason: "=cmd")
    get export_url("suppressions")
    assert_includes response.body, "'=cmd"
  end

  test "unknown exports 404" do
    get export_url("users")

    assert_response :not_found
  end

  test "export 404s when the workspace has no active project" do
    projects(:acme_default).update_columns(archived_at: Time.current)

    get export_url("emails")

    assert_response :not_found
  end
end

require "test_helper"

class SourcesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
  end

  test "index lists the project's sources with their webhook URLs" do
    get sources_url

    assert_response :success
    assert_match "production", response.body
    assert_match sources(:acme_production).webhook_token, response.body
    assert_no_match sources(:globex_production).webhook_token, response.body
  end

  test "create adds a source to the current project" do
    assert_difference -> { projects(:acme_default).sources.count }, +1 do
      post sources_url, params: { source: { name: "Staging", environment: "staging",
        region: "eu-west-1", default_from: "hello@acme.com", retention_days: 30,
        aws_access_key_id: "AKIA123", aws_secret_access_key: "secret123" } }
    end

    assert_redirected_to sources_url
  end

  test "create rejects a duplicate environment" do
    post sources_url, params: { source: { environment: "production", region: "eu-west-1" } }

    assert_response :unprocessable_entity
  end

  test "update keeps existing credentials when the fields are left blank" do
    source = sources(:acme_production)
    original_key = source.aws_secret_access_key

    patch source_url(source), params: { source: { name: "Renamed", aws_access_key_id: "",
      aws_secret_access_key: "" } }

    assert_redirected_to sources_url
    source.reload
    assert_equal "Renamed", source.name
    assert_equal original_key, source.aws_secret_access_key
  end

  test "quota sync refreshes the quota" do
    sources(:acme_production).update!(last_quota_checked_at: nil)

    post source_quota_sync_url(sources(:acme_production))

    assert_redirected_to sources_url
    assert sources(:acme_production).reload.last_quota_checked_at.present?
  end

  test "cross-tenant sources 404" do
    patch source_url(sources(:globex_production)), params: { source: { name: "Hacked" } }
    assert_response :not_found
  end

  test "mutations require the manage_domains capability" do
    sign_in_as users(:read_only)

    post sources_url, params: { source: { environment: "staging", region: "eu-west-1" } }
    assert_response :forbidden

    post source_quota_sync_url(sources(:acme_production))
    assert_response :forbidden
  end
end

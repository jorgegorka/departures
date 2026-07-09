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

  test "unknown exports 404" do
    get export_url("users")

    assert_response :not_found
  end
end

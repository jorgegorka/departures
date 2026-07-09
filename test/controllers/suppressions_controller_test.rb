require "test_helper"

class SuppressionsControllerTest < ActionDispatch::IntegrationTest
  test "index lists the project's suppressions" do
    sign_in_as users(:owner)
    get suppressions_url

    assert_response :success
    assert_select "body", text: /blocked@example.com/
  end

  test "create records a manual suppression" do
    sign_in_as users(:owner)

    assert_difference -> { Suppression.count }, +1 do
      post suppressions_url, params: { suppression: { email: "  NoMore@Example.com " } }
    end

    suppression = Suppression.order(:id).last
    assert_equal "nomore@example.com", suppression.email
    assert_equal "manual", suppression.reason
    assert_equal projects(:acme_default), suppression.project
  end

  test "create rejects a blank address with an alert" do
    sign_in_as users(:owner)

    assert_no_difference -> { Suppression.count } do
      post suppressions_url, params: { suppression: { email: "" } }
    end

    assert_redirected_to suppressions_url
    assert flash[:alert].present?
  end

  test "destroy removes a suppression from the current project only" do
    sign_in_as users(:owner)

    assert_difference -> { Suppression.count }, -1 do
      delete suppression_url(suppressions(:acme_blocked))
    end
  end

  test "actions 404 when the workspace has no active project" do
    sign_in_as users(:owner)
    projects(:acme_default).update_columns(archived_at: Time.current)

    get suppressions_url
    assert_response :not_found

    delete suppression_url(suppressions(:acme_blocked))
    assert_response :not_found
  end

  test "mutations require the send capability" do
    sign_in_as users(:read_only)

    post suppressions_url, params: { suppression: { email: "x@example.com" } }
    assert_response :forbidden

    delete suppression_url(suppressions(:acme_blocked))
    assert_response :forbidden
  end
end

require "test_helper"

class DashboardsControllerTest < ActionDispatch::IntegrationTest
  test "requires authentication" do
    get root_url

    assert_redirected_to new_session_url
  end

  test "defaults to the user's first workspace and active project" do
    sign_in_as users(:owner)

    get root_url

    assert_response :success
    assert_select "[data-workspace-slug=?]", "acme"
  end

  test "session workspace_id from another user's workspace is ignored" do
    sign_in_as users(:owner)

    get root_url(workspace_id: workspaces(:globex).id) # attempt via param is a no-op; session-based
    assert_response :success
    assert_select "[data-workspace-slug=?]", "acme"
  end
end

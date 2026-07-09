require "test_helper"

class Workspaces::SwitchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    # owner belongs to acme; add a second membership to switch into
    workspaces(:globex).memberships.create!(user: users(:owner), role: "member")
    sign_in_as users(:owner)
  end

  test "switching changes the current workspace" do
    post workspace_switch_url(workspaces(:globex))

    assert_redirected_to root_url
    follow_redirect!
    assert_select "[data-workspace-slug=?]", "globex"
  end

  test "cannot switch to a workspace the user does not belong to" do
    workspaces(:globex).memberships.where(user: users(:owner)).delete_all

    post workspace_switch_url(workspaces(:globex))

    assert_response :not_found
  end

  test "stale session workspace_id for a workspace the user no longer belongs to is ignored" do
    membership = workspaces(:globex).memberships.find_by(user: users(:owner))

    post workspace_switch_url(workspaces(:globex))
    assert_redirected_to root_url

    membership.destroy!

    get root_url
    assert_select "[data-workspace-slug=?]", "acme"
  end
end

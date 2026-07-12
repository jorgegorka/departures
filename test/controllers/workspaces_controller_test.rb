require "test_helper"

class WorkspacesControllerTest < ActionDispatch::IntegrationTest
  test "creating a workspace makes the creator its owner and switches to it" do
    sign_in_as users(:owner)

    assert_difference -> { Workspace.count }, +1 do
      post workspaces_url, params: { workspace: { name: "Side Project" } }
    end

    workspace = Workspace.order(:id).last
    assert_equal "owner", workspace.role_for(users(:owner))
    assert_redirected_to root_url
  end

  test "creating a workspace with a blank name re-renders with errors instead of 500" do
    sign_in_as users(:owner)

    assert_no_difference -> { Workspace.count } do
      post workspaces_url, params: { workspace: { name: "" } }
    end

    assert_response :unprocessable_entity
    assert_select "ul.txt-negative li"
  end

  test "owner can toggle require_two_factor" do
    sign_in_as users(:owner)

    patch workspace_path(workspaces(:acme)), params: { workspace: { require_two_factor: true } }

    assert_redirected_to edit_workspace_path(workspaces(:acme))
    assert workspaces(:acme).reload.require_two_factor?
  end

  test "non-owner cannot update the workspace" do
    sign_in_as users(:member)

    patch workspace_path(workspaces(:acme)), params: { workspace: { require_two_factor: true } }

    assert_response :forbidden
    assert_not workspaces(:acme).reload.require_two_factor?
  end

  test "updating a foreign workspace 404s" do
    sign_in_as users(:owner)

    patch workspace_path(workspaces(:globex)), params: { workspace: { require_two_factor: true } }

    assert_response :not_found
  end
end

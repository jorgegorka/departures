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
end

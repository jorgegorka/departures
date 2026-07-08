require "test_helper"

class Workspaces::InvitationsControllerTest < ActionDispatch::IntegrationTest
  test "a member without manage_members capability cannot invite" do
    sign_in_as users(:read_only)

    post workspace_invitations_url(workspaces(:acme)), params: { invitation: { email: "new@example.com", role: "member" } }

    assert_response :forbidden
  end

  test "a member with manage_members capability can invite" do
    sign_in_as users(:owner)

    assert_difference -> { Invitation.count }, +1 do
      assert_enqueued_jobs 1, only: ActionMailer::MailDeliveryJob do
        post workspace_invitations_url(workspaces(:acme)), params: { invitation: { email: "new@example.com", role: "member" } }
      end
    end

    assert_redirected_to root_url
  end
end

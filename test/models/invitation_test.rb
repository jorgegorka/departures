require "test_helper"

class InvitationTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "creating an invitation exposes the plaintext token once and stores a digest" do
    invitation = workspaces(:acme).invitations.create!(email: "new@example.com", role: "member")

    assert invitation.token.present?
    assert_equal Digest::SHA256.hexdigest(invitation.token), invitation.token_digest
    assert_equal users(:owner), invitation.invited_by
    assert invitation.expires_at > 6.days.from_now
  end

  test "find_by_token finds pending invitations only" do
    invitation = workspaces(:acme).invitations.create!(email: "new@example.com", role: "member")

    assert_equal invitation, Invitation.find_by_token(invitation.token)

    invitation.update! accepted_at: Time.current
    assert_nil Invitation.find_by_token(invitation.token)
  end

  test "expired invitations are not findable" do
    invitation = workspaces(:acme).invitations.create!(email: "new@example.com", role: "member")
    invitation.update! expires_at: 1.hour.ago

    assert_nil Invitation.find_by_token(invitation.token)
  end

  test "accept creates a membership with the invited role and stamps accepted_at" do
    invitation = workspaces(:acme).invitations.create!(email: "new@example.com", role: "sender")
    user = User.create!(email_address: "new@example.com",
      password: "secret123456", password_confirmation: "secret123456")

    assert_difference -> { Membership.count }, +1 do
      invitation.accept(user: user)
    end

    assert_equal "sender", workspaces(:acme).role_for(user)
    assert invitation.accepted_at.present?
  end

  test "accept is safe for a user who is already a member" do
    invitation = workspaces(:acme).invitations.create!(email: users(:member).email_address, role: "sender")

    assert_no_difference -> { Membership.count } do
      invitation.accept(user: users(:member))
    end

    assert_equal "member", workspaces(:acme).role_for(users(:member))
  end
end

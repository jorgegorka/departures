require "test_helper"

class Invitations::AcceptancesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Current.session = sessions(:owner)
    @invitation = workspaces(:acme).invitations.create!(email: "new@example.com", role: "member")
    @token = @invitation.token
    Current.reset
  end

  test "unsigned visitor sees prefilled email on GET" do
    get new_invitation_acceptance_url(invitation_token: @token)

    assert_response :success
    assert_select "input[name=email_address][value=?]", "new@example.com"
  end

  test "a signed-in user accepts directly" do
    sign_in_as users(:outsider)

    assert_difference -> { Membership.count }, +1 do
      post invitation_acceptance_url(invitation_token: @token)
    end

    assert_redirected_to root_url
    assert_equal "member", workspaces(:acme).role_for(users(:outsider))
  end

  test "a new visitor creates an account and accepts in one step" do
    assert_difference -> { User.count } => +1, -> { Membership.count } => +1 do
      post invitation_acceptance_url(invitation_token: @token), params: {
        email_address: "new@example.com", password: "secret123456", password_confirmation: "secret123456" }
    end

    assert_redirected_to root_url
  end

  test "a submitted email_address cannot override the invitation's email" do
    assert_difference -> { User.count } => +1, -> { Membership.count } => +1 do
      post invitation_acceptance_url(invitation_token: @token), params: {
        email_address: "attacker@evil.com", password: "secret123456", password_confirmation: "secret123456" }
    end

    assert_redirected_to root_url

    user = User.find_by!(email_address: "new@example.com")
    assert_nil User.find_by(email_address: "attacker@evil.com")
    assert_equal "member", workspaces(:acme).role_for(user)
  end

  test "an invitation to an already-registered email cannot create a duplicate account" do
    Current.session = sessions(:owner)
    invitation = workspaces(:acme).invitations.create!(email: users(:member).email_address, role: "member")
    Current.reset

    assert_no_difference -> { User.count } do
      assert_no_difference -> { Membership.count } do
        post invitation_acceptance_url(invitation_token: invitation.token), params: {
          password: "secret123456", password_confirmation: "secret123456" }
      end
    end

    assert_response :unprocessable_entity
  end

  test "a visitor with a mismatched password confirmation cannot create an account" do
    assert_no_difference -> { User.count } do
      post invitation_acceptance_url(invitation_token: @token), params: {
        email_address: "new@example.com", password: "secret123456", password_confirmation: "nope" }
    end

    assert_response :unprocessable_entity
  end

  test "invalid token is not found" do
    post invitation_acceptance_url(invitation_token: "bogus")

    assert_response :not_found
  end
end

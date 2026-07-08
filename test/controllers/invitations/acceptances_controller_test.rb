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

  test "a visitor with an already-registered email cannot create a duplicate account" do
    assert_no_difference -> { User.count } do
      assert_no_difference -> { Membership.count } do
        post invitation_acceptance_url(invitation_token: @token), params: {
          email_address: users(:member).email_address, password: "secret123456", password_confirmation: "secret123456" }
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

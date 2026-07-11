require "test_helper"

class TwoFactorEnforcementTest < ActionDispatch::IntegrationTest
  setup do
    workspaces(:acme).update!(require_two_factor: true)
    @user = users(:member)
    sign_in_as @user
  end

  test "an unenrolled member of an enforcing workspace is redirected to enrollment" do
    get root_path
    assert_redirected_to new_two_factor_path
  end

  test "the enrollment screens themselves stay reachable (no redirect loop)" do
    get new_two_factor_path
    assert_response :success
  end

  test "sign-out stays reachable" do
    delete session_path
    assert_redirected_to new_session_path
  end

  test "an enrolled member passes through" do
    enable_two_factor_for @user

    get root_path
    assert_response :success
  end

  test "a member of a non-enforcing workspace is unaffected" do
    workspaces(:acme).update!(require_two_factor: false)

    get root_path
    assert_response :success
  end
end

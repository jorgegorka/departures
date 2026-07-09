require "test_helper"

class OnboardingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
  end

  test "an un-onboarded workspace is redirected to onboarding from gated pages" do
    workspaces(:acme).update!(onboarded_at: nil)

    get root_url
    assert_redirected_to onboarding_url

    get activity_url
    assert_redirected_to onboarding_url
  end

  test "onboarding-flow pages stay reachable while un-onboarded" do
    workspaces(:acme).update!(onboarded_at: nil)

    get onboarding_url
    assert_response :success

    get sources_url
    assert_response :success

    get domains_url
    assert_response :success

    get api_keys_url
    assert_response :success

    get new_test_email_url
    assert_response :success

    delete session_url
    assert_response :redirect
  end

  test "showing onboarding stamps setup_started_at" do
    workspaces(:acme).update!(onboarded_at: nil, setup_started_at: nil)

    get onboarding_url

    assert workspaces(:acme).reload.setup_started_at.present?
  end

  test "the checklist reflects step completion" do
    workspaces(:acme).update!(onboarded_at: nil)

    get onboarding_url

    assert_response :success
    assert_match "Add a source", response.body
    assert_match "Verify a domain", response.body
    assert_match "Issue an API key", response.body
    assert_match "Send a test email", response.body
  end

  test "completion marks the workspace onboarded and unlocks the dashboard" do
    workspaces(:acme).update!(onboarded_at: nil)

    post onboarding_completion_url
    assert_redirected_to root_url
    assert workspaces(:acme).reload.onboarded?

    get root_url
    assert_response :success
  end

  test "an onboarded workspace is never gated" do
    get root_url
    assert_response :success
  end
end

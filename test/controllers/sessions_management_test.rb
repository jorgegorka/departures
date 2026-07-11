require "test_helper"

class SessionsManagementTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:owner)
    sign_in_as @user
  end

  test "index lists only my sessions" do
    get user_sessions_path

    assert_response :success
    assert_match "Minitest", response.body
  end

  test "index touches activity on the current session" do
    get user_sessions_path
    assert @user.sessions.order(created_at: :desc).first.last_active_at.present?
  end

  test "revoking another of my sessions keeps me signed in" do
    other = @user.sessions.create!(user_agent: "OtherBrowser", ip_address: "10.0.0.1")

    delete user_session_path(other)

    assert_redirected_to user_sessions_path
    assert_not Session.exists?(other.id)
    get user_sessions_path
    assert_response :success
  end

  test "revoking my current session signs me out" do
    current = @user.sessions.order(created_at: :desc).first

    delete user_session_path(current)

    assert_redirected_to new_session_path
    get user_sessions_path
    assert_redirected_to new_session_path
  end

  test "revoking a foreign session 404s" do
    delete user_session_path(sessions(:read_only))
    assert_response :not_found
  end

  test "other_sessions destroy removes everything but the current session" do
    @user.sessions.create!(user_agent: "OtherBrowser", ip_address: "10.0.0.1")
    @user.sessions.create!(user_agent: "ThirdBrowser", ip_address: "10.0.0.2")

    delete other_sessions_path

    assert_redirected_to user_sessions_path
    assert_equal 1, @user.sessions.count
  end
end

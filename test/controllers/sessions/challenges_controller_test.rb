require "test_helper"

class Sessions::ChallengesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:jorge)
    @codes = enable_two_factor_for(@user)
  end

  test "password login for a 2FA user creates no session and redirects to the challenge" do
    post session_path, params: { email_address: @user.email_address, password: "secret123456" }

    assert_redirected_to new_challenge_path
    assert_nil cookies[:session_id].presence
  end

  test "challenge with a valid TOTP creates the session" do
    start_challenge
    travel 1.minute do
      post challenge_path, params: { code: Totp.new(@user.reload.otp_secret).code }
    end

    assert_redirected_to root_path
    assert cookies[:session_id].present?
  end

  test "challenge with a recovery code creates the session and consumes the code" do
    start_challenge

    post challenge_path, params: { code: @codes.first }

    assert_redirected_to root_path
    assert cookies[:session_id].present?
    assert_equal 9, @user.reload.otp_recovery_codes.length
  end

  test "challenge with an invalid code re-renders and creates no session" do
    start_challenge

    post challenge_path, params: { code: "000000" }

    assert_redirected_to new_challenge_path
    assert_nil cookies[:session_id].presence
  end

  test "the code param is filtered from request logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

    assert_equal "[FILTERED]", filter.filter(code: "a1b2c3d4e5")[:code]
  end

  test "challenge without a pending login redirects to sign-in" do
    get new_challenge_path
    assert_redirected_to new_session_path
  end

  test "challenge is rate limited" do
    start_challenge

    11.times { post challenge_path, params: { code: "000000" } }

    assert_redirected_to new_challenge_path
    assert_equal "Try again later.", flash[:alert]
    assert_nil cookies[:session_id].presence
  end

  test "non-2FA users still log in in one step" do
    plain = users(:member)

    post session_path, params: { email_address: plain.email_address, password: "secret123456" }

    assert_redirected_to root_path
    assert cookies[:session_id].present?
  end

  private
    def start_challenge
      post session_path, params: { email_address: @user.email_address, password: "secret123456" }
    end
end

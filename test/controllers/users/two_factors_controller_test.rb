require "test_helper"

class Users::TwoFactorsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:owner)
    sign_in_as @user
  end

  test "new prepares a secret and shows the provisioning details" do
    get new_two_factor_path

    assert_response :success
    assert @user.reload.otp_secret.present?
    assert @user.two_factor_disabled?
    assert_match "otpauth://totp/", response.body
  end

  test "create with correct password and code enables 2FA and reveals recovery codes once" do
    get new_two_factor_path
    code = Totp.new(@user.reload.otp_secret).code

    post two_factor_path, params: { password: "secret123456", code: code }

    assert_response :success
    assert @user.reload.two_factor_enabled?
    assert_select "code", minimum: 10
  end

  test "create with wrong password does not enable" do
    get new_two_factor_path
    code = Totp.new(@user.reload.otp_secret).code

    post two_factor_path, params: { password: "wrong", code: code }

    assert_redirected_to new_two_factor_path
    assert @user.reload.two_factor_disabled?
  end

  test "create with wrong code does not enable" do
    get new_two_factor_path

    post two_factor_path, params: { password: "secret123456", code: "000000" }

    assert_redirected_to new_two_factor_path
    assert @user.reload.two_factor_disabled?
  end

  test "destroy with correct password disables 2FA" do
    enable_two_factor_for @user

    delete two_factor_path, params: { password: "secret123456" }

    assert_redirected_to root_path
    assert @user.reload.two_factor_disabled?
  end

  test "destroy with wrong password keeps 2FA on" do
    enable_two_factor_for @user

    delete two_factor_path, params: { password: "wrong" }

    assert @user.reload.two_factor_enabled?
  end

  test "recovery codes can be regenerated with password" do
    enable_two_factor_for @user
    old_digests = @user.reload.otp_recovery_codes

    post recovery_codes_path, params: { password: "secret123456" }

    assert_response :success
    assert_not_equal old_digests, @user.reload.otp_recovery_codes
  end

  test "new redirects when already enrolled without rotating the secret" do
    enable_two_factor_for @user
    secret_before = @user.reload.otp_secret

    get new_two_factor_path

    assert_redirected_to user_sessions_path
    assert_equal secret_before, @user.reload.otp_secret
  end

  test "create redirects when already enrolled" do
    enable_two_factor_for @user

    post two_factor_path, params: { password: "secret123456", code: "000000" }

    assert_redirected_to user_sessions_path
    assert @user.reload.two_factor_enabled?
  end
end

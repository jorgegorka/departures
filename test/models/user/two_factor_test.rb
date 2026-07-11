require "test_helper"

class User::TwoFactorTest < ActiveSupport::TestCase
  setup do
    @user = users(:jorge)
    @user.prepare_two_factor
    @totp = Totp.new(@user.otp_secret)
  end

  test "prepare_two_factor stores an encrypted secret while still disabled" do
    assert @user.otp_secret.present?
    assert @user.two_factor_disabled?
    assert_not_equal @user.otp_secret, @user.read_attribute_before_type_cast(:otp_secret)
  end

  test "enable_two_factor with a valid code enables and returns ten recovery codes" do
    codes = @user.enable_two_factor(@totp.code)

    assert @user.two_factor_enabled?
    assert_equal 10, codes.length
    assert_equal 10, @user.otp_recovery_codes.length
    codes.each { |code| assert_not_includes @user.otp_recovery_codes, code } # digests stored, not plaintext
  end

  test "enable_two_factor with an invalid code returns false and stays disabled" do
    assert_equal false, @user.enable_two_factor("000000")
    assert @user.two_factor_disabled?
  end

  test "verify_totp accepts a fresh code once and refuses its replay" do
    @user.enable_two_factor(@totp.code)
    fresh = @totp.code(at: 1.minute.from_now)

    assert @user.verify_totp(fresh, at: 1.minute.from_now)
    assert_not @user.verify_totp(fresh, at: 1.minute.from_now)
  end

  test "verify_totp refuses codes when disabled" do
    assert_not @user.verify_totp(@totp.code)
  end

  test "redeem_recovery_code consumes a code exactly once" do
    codes = @user.enable_two_factor(@totp.code)

    assert @user.redeem_recovery_code(codes.first)
    assert_not @user.redeem_recovery_code(codes.first)
    assert_equal 9, @user.otp_recovery_codes.length
  end

  test "redeem_recovery_code accepts an uppercase-entered code" do
    codes = @user.enable_two_factor(@totp.code)

    assert @user.redeem_recovery_code(codes.first.upcase)
    assert_equal 9, @user.otp_recovery_codes.length
  end

  test "redeem_recovery_code refuses unknown codes" do
    @user.enable_two_factor(@totp.code)
    assert_not @user.redeem_recovery_code("nope")
  end

  test "regenerate_recovery_codes invalidates the old set" do
    old_codes = @user.enable_two_factor(@totp.code)
    new_codes = @user.regenerate_recovery_codes

    assert_not @user.redeem_recovery_code(old_codes.first)
    assert @user.redeem_recovery_code(new_codes.first)
  end

  test "disable_two_factor clears everything" do
    @user.enable_two_factor(@totp.code)
    @user.disable_two_factor

    assert @user.two_factor_disabled?
    assert_nil @user.otp_secret
    assert_nil @user.otp_consumed_timestep
    assert_empty @user.otp_recovery_codes
  end
end

require "test_helper"

class TotpTest < ActiveSupport::TestCase
  # RFC 6238 Appendix B vectors (SHA-1), truncated to 6 digits.
  # Secret is ASCII "12345678901234567890" in Base32.
  RFC_SECRET = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

  RFC_VECTORS = {
    59 => "287082",
    1_111_111_109 => "081804",
    1_111_111_111 => "050471",
    1_234_567_890 => "005924",
    2_000_000_000 => "279037"
  }.freeze

  setup do
    @totp = Totp.new(RFC_SECRET)
  end

  test "code matches the RFC 6238 test vectors" do
    RFC_VECTORS.each do |unix_time, expected|
      assert_equal expected, @totp.code(at: Time.at(unix_time)), "at T=#{unix_time}"
    end
  end

  test "verify returns the matched timestep for a current code" do
    at = Time.at(1_111_111_111)
    assert_equal 1_111_111_111 / 30, @totp.verify("050471", at: at)
  end

  test "verify accepts codes one step behind or ahead (drift window)" do
    at = Time.at(1_111_111_111)
    assert @totp.verify(@totp.code(at: at - 30), at: at)
    assert @totp.verify(@totp.code(at: at + 30), at: at)
  end

  test "verify rejects codes outside the drift window" do
    at = Time.at(1_111_111_111)
    assert_nil @totp.verify(@totp.code(at: at - 90), at: at)
    assert_nil @totp.verify(@totp.code(at: at + 90), at: at)
  end

  test "verify rejects malformed codes" do
    assert_nil @totp.verify(nil)
    assert_nil @totp.verify("")
    assert_nil @totp.verify("12345")
    assert_nil @totp.verify("abcdef")
    assert_nil @totp.verify("1234567")
  end

  test "generate_secret returns 32 Base32 characters" do
    secret = Totp.generate_secret
    assert_match(/\A[A-Z2-7]{32}\z/, secret)
    assert_not_equal secret, Totp.generate_secret
  end

  test "provisioning_uri encodes issuer and account" do
    uri = Totp.new("ABC234").provisioning_uri(account: "ann@example.com")
    assert_equal "otpauth://totp/Departures:ann%40example.com?secret=ABC234&issuer=Departures", uri
  end
end

require "test_helper"

class EmailAddressTest < ActiveSupport::TestCase
  test "address_part returns the bare addr-spec for a plain address" do
    assert_equal "ann@example.com", EmailAddress.address_part("ann@example.com")
  end

  test "address_part extracts the addr-spec from a display-name address" do
    assert_equal "ann@example.com", EmailAddress.address_part("Ann Smith <ann@example.com>")
  end

  test "address_part returns nil for unparseable garbage" do
    assert_nil EmailAddress.address_part("<<<")
    assert_nil EmailAddress.address_part("garbage @ two @ ats")
  end

  test "address_part returns nil for blank input" do
    assert_nil EmailAddress.address_part("")
    assert_nil EmailAddress.address_part(nil)
  end

  test "valid? accepts plain and display-name addresses" do
    assert EmailAddress.valid?("ann@example.com")
    assert EmailAddress.valid?("Ann Smith <ann@example.com>")
  end

  test "valid? rejects an address with no domain" do
    assert_not EmailAddress.valid?("no-at-sign")
  end

  test "valid? rejects garbage" do
    assert_not EmailAddress.valid?("<<<")
    assert_not EmailAddress.valid?("")
    assert_not EmailAddress.valid?(nil)
  end

  test "valid? rejects an addr-spec longer than 320 chars" do
    long = "#{"a" * 314}@ex.com" # 321 chars
    assert_equal 321, long.length
    assert_not EmailAddress.valid?(long)
  end
end

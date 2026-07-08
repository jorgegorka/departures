require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "downcases and strips email_address" do
    user = User.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", user.email_address)
  end

  test "registration_open? is true when there are no users" do
    Membership.delete_all
    Workspace.delete_all
    Session.delete_all
    User.delete_all

    assert User.registration_open?
  end

  test "registration_open? is false when users exist" do
    assert_not User.registration_open?
  end

  test "registration_open? is true with OPEN_REGISTRATION set" do
    ENV["OPEN_REGISTRATION"] = "true"

    assert User.registration_open?
  ensure
    ENV.delete("OPEN_REGISTRATION")
  end
end

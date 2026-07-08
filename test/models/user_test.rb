require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "downcases and strips email_address" do
    user = User.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", user.email_address)
  end

  test "registration_open? is true when there are no users" do
    Membership.delete_all
    Source.delete_all
    ApiKey.delete_all
    Project.delete_all
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

  test "create_owner creates user, workspace, and owner membership" do
    user = nil

    assert_difference -> { User.count } => +1, -> { Workspace.count } => +1, -> { Membership.count } => +1 do
      user = User.create_owner(email_address: "founder@example.com",
        password: "secret123456", password_confirmation: "secret123456")
    end

    workspace = user.workspaces.sole
    assert_equal user, workspace.owner
    assert_equal "owner", workspace.role_for(user)
  end
end

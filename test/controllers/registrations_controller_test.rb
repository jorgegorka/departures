require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  test "first user can register and becomes a workspace owner" do
    wipe_workspace_records

    assert_difference -> { User.count } => +1, -> { Workspace.count } => +1 do
      post registration_url, params: { email_address: "first@example.com",
        password: "secret123456", password_confirmation: "secret123456" }
    end

    assert_equal "owner", Workspace.sole.role_for(User.sole)
    assert_redirected_to root_url
  end

  test "registration is closed when users exist" do
    assert_no_difference -> { User.count } do
      post registration_url, params: { email_address: "second@example.com",
        password: "secret123456", password_confirmation: "secret123456" }
    end

    assert_response :not_found
  end

  test "new is not available when registration closed" do
    get new_registration_url

    assert_response :not_found
  end

  test "mismatched password confirmation does not create a user" do
    wipe_workspace_records

    assert_no_difference -> { User.count } do
      post registration_url, params: { email_address: "first@example.com",
        password: "secret123456", password_confirmation: "nope" }
    end

    assert_response :unprocessable_entity
  end

  test "two users with colliding email localparts both register with distinct workspace slugs" do
    wipe_workspace_records

    ENV["OPEN_REGISTRATION"] = "1"

    assert_difference -> { User.count } => +2, -> { Workspace.count } => +2 do
      post registration_url, params: { email_address: "jorge@a.com",
        password: "secret123456", password_confirmation: "secret123456" }
      assert_redirected_to root_url

      post registration_url, params: { email_address: "jorge@b.com",
        password: "secret123456", password_confirmation: "secret123456" }
      assert_redirected_to root_url
    end

    slugs = Workspace.order(:id).pluck(:slug)
    assert_equal slugs.uniq, slugs
  ensure
    ENV.delete("OPEN_REGISTRATION")
  end

  test "new renders a flat-params registration form when registration is open" do
    wipe_workspace_records

    get new_registration_url

    assert_response :success
    assert_select "input[name=?]", "email_address"
    assert_select "input[name=?]", "password"
    assert_select "input[name=?]", "password_confirmation"
  end
end

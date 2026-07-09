require "test_helper"

class ApiKeysControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
    @api_key = ApiKey.issue(project: projects(:acme_default), name: "CI", scopes: %w[ send ])
  end

  test "index lists the project's keys by prefix, never the token" do
    get api_keys_url

    assert_response :success
    assert_match @api_key.prefix, response.body
    assert_no_match @api_key.token, response.body
  end

  test "create issues a key and reveals the token exactly once" do
    assert_difference -> { projects(:acme_default).api_keys.count }, +1 do
      post api_keys_url, params: { api_key: { name: "Production app", scopes: [ "send", "read:activity" ],
        expires_in: "90" } }
    end

    assert_response :success
    assert_match(/dp_[A-Za-z0-9]{48}/, response.body)

    key = ApiKey.order(:id).last
    assert_equal %w[ send read:activity ], key.scopes
    assert key.expires_at.between?(89.days.from_now, 91.days.from_now)

    get api_keys_url
    assert_no_match(/dp_[A-Za-z0-9]{48}/, response.body)
  end

  test "create without expiry issues a non-expiring key" do
    post api_keys_url, params: { api_key: { name: "Forever", scopes: [ "send" ], expires_in: "" } }

    assert_response :success
    assert_nil ApiKey.order(:id).last.expires_at
  end

  test "destroy revokes without deleting" do
    assert_no_difference -> { ApiKey.count } do
      delete api_key_url(@api_key)
    end

    assert_redirected_to api_keys_url
    assert @api_key.reload.revoked?
  end

  test "rotation revokes the old key and reveals a new one" do
    assert_difference -> { projects(:acme_default).api_keys.count }, +1 do
      post api_key_rotation_url(@api_key)
    end

    assert_response :success
    assert_match(/dp_[A-Za-z0-9]{48}/, response.body)
    assert @api_key.reload.revoked?
  end

  test "cross-tenant keys 404" do
    foreign = ApiKey.issue(project: projects(:globex_default), scopes: %w[ send ])

    delete api_key_url(foreign)
    assert_response :not_found

    post api_key_rotation_url(foreign)
    assert_response :not_found
  end

  test "mutations require the manage_api_keys capability" do
    sign_in_as users(:sender)

    post api_keys_url, params: { api_key: { name: "X", scopes: [ "send" ] } }
    assert_response :forbidden

    delete api_key_url(@api_key)
    assert_response :forbidden
  end
end

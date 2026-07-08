require "test_helper"

class ApiKeyTest < ActiveSupport::TestCase
  ACME_FULL_TOKEN = "dp_#{"acme" * 12}".freeze

  setup do
    Current.session = sessions(:owner)
  end

  test "issue returns a key exposing the plaintext token exactly once" do
    api_key = ApiKey.issue(project: projects(:acme_default), scopes: %w[ send ])

    assert api_key.persisted?
    assert api_key.token.start_with?("dp_")
    assert_equal 51, api_key.token.length
    assert_equal api_key.token.first(12), api_key.prefix
    assert_equal Digest::SHA256.hexdigest(api_key.token), api_key.key_hash
    assert_equal workspaces(:acme), api_key.workspace
    assert_nil ApiKey.find(api_key.id).token
  end

  test "issue with expires_in sets expiry" do
    api_key = ApiKey.issue(project: projects(:acme_default), scopes: %w[ send ], expires_in: 30.days)

    assert_in_delta 30.days.from_now, api_key.expires_at, 5.seconds
  end

  test "authenticate_by_token finds the key by sha256" do
    assert_equal api_keys(:acme_full), ApiKey.authenticate_by_token(ACME_FULL_TOKEN)
  end

  test "authenticate_by_token rejects unknown, revoked, and expired tokens" do
    assert_nil ApiKey.authenticate_by_token("dp_bogus")
    assert_nil ApiKey.authenticate_by_token("dp_#{"gone" * 12}")
    assert_nil ApiKey.authenticate_by_token("dp_#{"late" * 12}")
    assert_nil ApiKey.authenticate_by_token(nil)
  end

  test "revoke is idempotent and flips active?" do
    api_key = api_keys(:acme_full)
    assert api_key.active?

    api_key.revoke
    first_revoked_at = api_key.revoked_at
    assert api_key.revoked?
    assert_not api_key.active?

    api_key.revoke
    assert_equal first_revoked_at, api_key.revoked_at
  end

  test "rotate revokes the old key and issues a replacement with the same scopes" do
    api_key = api_keys(:acme_full)

    replacement = api_key.rotate

    assert api_key.reload.revoked?
    assert replacement.persisted?
    assert replacement.token.present?
    assert_equal api_key.scopes, replacement.scopes
    assert_equal api_key.project, replacement.project
  end

  test "allows? checks scopes" do
    assert api_keys(:acme_full).allows?("send")
    assert api_keys(:acme_read_only).allows?("read:activity")
    assert_not api_keys(:acme_read_only).allows?("send")
  end

  test "touch_usage records telemetry at most once per minute" do
    api_key = api_keys(:acme_full)

    api_key.touch_usage(ip: "1.2.3.4", user_agent: "curl")
    first_touch = api_key.reload.last_used_at
    assert_equal "1.2.3.4", api_key.last_used_ip

    api_key.touch_usage(ip: "5.6.7.8", user_agent: "curl")
    assert_equal first_touch, api_key.reload.last_used_at
    assert_equal "1.2.3.4", api_key.last_used_ip

    api_key.update_columns(last_used_at: 2.minutes.ago)
    api_key.touch_usage(ip: "5.6.7.8", user_agent: "curl")
    assert_equal "5.6.7.8", api_key.reload.last_used_ip
  end
end

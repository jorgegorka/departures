require "test_helper"

class AuditInstrumentationTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    Current.workspace = workspaces(:acme)
  end

  teardown do
    Current.reset
  end

  test "issuing, revoking and rotating an API key are audited" do
    api_key = ApiKey.issue(project: projects(:acme_default), scopes: %w[ send ])
    assert_audited "api_key.issued", subject: api_key

    api_key.revoke
    assert_audited "api_key.revoked", subject: api_key

    rotated = api_keys(:acme_full).rotate
    assert_audited "api_key.rotated", subject: api_keys(:acme_full)
    assert_audited "api_key.issued", subject: rotated
  end

  test "accepting an invitation is audited" do
    invitation = workspaces(:acme).invitations.create!(email: "new@example.com", role: "member")
    invitation.accept(user: users(:outsider))

    assert_audited "invitation.accepted", subject: invitation
  end

  test "a domain flipping to verified is audited" do
    domain = domains(:acme_pending)
    domain.ses_client.stub_responses(:get_email_identity, verified_for_sending_status: true, dkim_attributes: { tokens: %w[ a b c ] })

    domain.check

    assert_audited "domain.verified", subject: domain
  end

  test "2FA lifecycle is audited" do
    user = users(:jorge)
    user.prepare_two_factor
    user.enable_two_factor(Totp.new(user.otp_secret).code)
    assert_audited "two_factor.enabled", subject: user

    codes = user.regenerate_recovery_codes
    assert_audited "two_factor.recovery_codes_regenerated", subject: user

    user.redeem_recovery_code(codes.first)
    assert_audited "two_factor.recovery_code_redeemed", subject: user

    user.disable_two_factor
    assert_audited "two_factor.disabled", subject: user
  end

  private
    def assert_audited(action, subject:)
      assert AuditEvent.exists?(action: action, subject: subject), "expected an audit event #{action} for #{subject.class}##{subject.id}"
    end
end

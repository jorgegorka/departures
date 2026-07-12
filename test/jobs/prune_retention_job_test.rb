require "test_helper"

class PruneRetentionJobTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    wipe_send_domain
  end

  test "perform prunes every retention-bound table in one pass" do
    source = sources(:acme_production)
    expired_email = Email.create!(project: source.project, source: source, from: "hello@acme.com",
      subject: "Old", html_body: "<p>old</p>", status: "sent", created_at: 31.days.ago)
    fresh_email = Email.create!(project: source.project, source: source, from: "hello@acme.com",
      subject: "New", html_body: "<p>new</p>")
    old_log = WebhookLog.create!(source: source, message_type: "Notification",
      payload: {}, created_at: 31.days.ago)
    expired_idempotency = IdempotencyKey.create!(api_key: api_keys(:acme_full), email: fresh_email,
      key: "prune-test-key", fingerprint: "f", expires_at: 1.hour.ago)
    expired_invitation = Invitation.create!(workspace: workspaces(:acme), email: "late@example.com",
      role: "member", expires_at: 1.day.ago)
    old_audit = AuditEvent.create!(action: "domain.created", created_at: 181.days.ago)
    fresh_audit = AuditEvent.create!(action: "domain.created")

    PruneRetentionJob.perform_now

    assert_not Email.exists?(expired_email.id)
    assert Email.exists?(fresh_email.id)
    assert_not WebhookLog.exists?(old_log.id)
    assert_not IdempotencyKey.exists?(expired_idempotency.id)
    assert_not Invitation.exists?(expired_invitation.id)
    assert_not AuditEvent.exists?(old_audit.id)
    assert AuditEvent.exists?(fresh_audit.id)
  end
end

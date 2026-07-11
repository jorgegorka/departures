require "test_helper"

class AuditEventTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    Current.workspace = workspaces(:acme)
    Current.ip = "203.0.113.7"
  end

  teardown do
    Current.reset
  end

  test "record captures actor, workspace and ip from Current" do
    event = AuditEvent.record("api_key.revoked", subject: api_keys(:acme_full), metadata: { prefix: "dp_abc" })

    assert_equal users(:owner), event.user
    assert_equal workspaces(:acme), event.workspace
    assert_equal "203.0.113.7", event.ip
    assert_equal api_keys(:acme_full), event.subject
    assert_equal "dp_abc", event.metadata["prefix"]
  end

  test "record tolerates a missing workspace and user" do
    Current.reset

    event = AuditEvent.record("two_factor.recovery_code_redeemed")

    assert_nil event.workspace
    assert_nil event.user
  end

  test "record refuses unknown actions" do
    assert_raises ActiveRecord::RecordInvalid do
      AuditEvent.record("made_up.action")
    end
  end

  test "indexed_by and in_time_range narrow the list" do
    AuditEvent.record("api_key.revoked")
    AuditEvent.record("two_factor.enabled")
    AuditEvent.record("domain.created").update_column(:created_at, 8.days.ago)

    assert_equal 1, AuditEvent.indexed_by("api_keys").count
    assert_equal 1, AuditEvent.indexed_by("security").count
    assert_equal 3, AuditEvent.indexed_by(nil).count
    assert_equal 2, AuditEvent.in_time_range("7d").count
  end

  test "prune removes events older than 180 days" do
    fresh = AuditEvent.record("api_key.revoked")
    stale = AuditEvent.record("api_key.revoked")
    stale.update_column(:created_at, 181.days.ago)

    AuditEvent.prune

    assert AuditEvent.exists?(fresh.id)
    assert_not AuditEvent.exists?(stale.id)
  end
end

require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "deletable? requires archived and no emails" do
    project = projects(:globex_default)
    assert_not project.deletable?

    project.archive
    assert project.deletable?

    project.emails.create!(source: sources(:globex_production), from: "hello@globex.com", subject: "Hi")
    assert_not project.deletable?
  end

  test "destroying a project cascades through emails, api keys, sources, suppressions, and idempotency keys" do
    project = projects(:acme_default)
    IdempotencyKey.create!(api_key: api_keys(:acme_full), email: emails(:acme_welcome),
      key: "req-1", fingerprint: "fp-1", expires_at: IdempotencyKey::EXPIRY.from_now)

    assert_nothing_raised { project.destroy! }

    assert_empty Email.where(project_id: project.id)
    assert_empty ApiKey.where(project_id: project.id)
    assert_empty Source.where(project_id: project.id)
    assert_empty Suppression.where(project_id: project.id)
    assert_equal 0, IdempotencyKey.count
  end
end

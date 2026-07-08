require "test_helper"

class WorkspaceTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "destroying a workspace cascades end-to-end" do
    workspace = workspaces(:acme)
    IdempotencyKey.create!(api_key: api_keys(:acme_full), email: emails(:acme_welcome),
      key: "req-1", fingerprint: "fp-1", expires_at: IdempotencyKey::EXPIRY.from_now)

    assert_nothing_raised { workspace.destroy! }

    assert_empty Project.where(workspace_id: workspace.id)
    assert_empty Email.where(workspace_id: workspace.id)
    assert_empty ApiKey.where(workspace_id: workspace.id)
    assert_empty Membership.where(workspace_id: workspace.id)
    assert_equal 0, IdempotencyKey.count
  end
end

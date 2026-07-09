require "test_helper"

class CurrentTest < ActiveSupport::TestCase
  test "workspace and project are settable attributes" do
    Current.workspace = workspaces(:acme)
    Current.project = projects(:acme_default)

    assert_equal workspaces(:acme), Current.workspace
    assert_equal projects(:acme_default), Current.project
  end
end

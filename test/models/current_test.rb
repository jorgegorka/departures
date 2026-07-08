require "test_helper"

class CurrentTest < ActiveSupport::TestCase
  test "workspace and project are settable attributes" do
    Current.workspace = "workspace-sentinel"
    Current.project = "project-sentinel"

    assert_equal "workspace-sentinel", Current.workspace
    assert_equal "project-sentinel", Current.project
  end
end

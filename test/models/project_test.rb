require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  test "deletable? requires archived and no emails" do
    project = projects(:globex_default)
    assert_not project.deletable?

    project.archive
    assert project.deletable?

    project.emails.create!(source: sources(:globex_production), from: "hello@globex.com", subject: "Hi")
    assert_not project.deletable?
  end
end

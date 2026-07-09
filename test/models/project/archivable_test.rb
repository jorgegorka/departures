require "test_helper"

class Project::ArchivableTest < ActiveSupport::TestCase
  test "archive and unarchive round-trip" do
    project = projects(:acme_default)
    assert project.active?

    project.archive
    assert project.archived?
    assert_not project.active?
    assert_includes Project.archived, project
    assert_not_includes Project.active, project

    project.unarchive
    assert project.active?
    assert_includes Project.active, project
  end

  test "archive is idempotent" do
    project = projects(:acme_default)
    project.archive
    first_archived_at = project.archived_at

    project.archive
    assert_equal first_archived_at, project.archived_at
  end
end

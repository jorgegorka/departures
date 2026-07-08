require "test_helper"

class SuppressionTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "active includes permanent and unexpired suppressions only" do
    assert_includes Suppression.active, suppressions(:acme_blocked)
    assert_includes Suppression.active, suppressions(:acme_temporary)
    assert_not_includes Suppression.active, suppressions(:acme_lapsed)
  end

  test "covers? returns the suppressed subset" do
    covered = Suppression.covers?(projects(:acme_default),
      %w[ blocked@example.com fine@example.com temporary@example.com ])

    assert_equal %w[ blocked@example.com temporary@example.com ], covered.sort
  end

  test "covers? ignores expired suppressions" do
    assert_empty Suppression.covers?(projects(:acme_default), %w[ lapsed@example.com ])
  end

  test "covers? is project-scoped" do
    assert_empty Suppression.covers?(projects(:globex_default), %w[ blocked@example.com ])
  end

  test "covers? normalizes case and whitespace" do
    assert_equal %w[ blocked@example.com ], Suppression.covers?(projects(:acme_default), [ " Blocked@Example.COM " ])
  end

  test "email is unique per project and workspace defaults from project" do
    suppression = projects(:globex_default).suppressions.create!(email: "blocked@example.com", reason: "manual")
    assert_equal workspaces(:globex), suppression.workspace

    assert_raises ActiveRecord::RecordInvalid do
      projects(:acme_default).suppressions.create!(email: "blocked@example.com", reason: "manual")
    end
  end
end

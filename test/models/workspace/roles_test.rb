require "test_helper"

class Workspace::RolesTest < ActiveSupport::TestCase
  fixtures :users, :workspaces, :memberships
  CAPABILITIES = %w[ send manage_api_keys manage_domains manage_templates manage_webhooks manage_members ]

  EXPECTED = {
    "owner"     => CAPABILITIES,
    "member"    => CAPABILITIES - %w[ manage_members ],
    "sender"    => %w[ send ],
    "api_keys"  => %w[ manage_api_keys ],
    "domains"   => %w[ manage_domains ],
    "read_only" => []
  }.freeze

  test "role capability matrix" do
    EXPECTED.each do |role, allowed|
      user = users(role.to_sym)

      CAPABILITIES.each do |capability|
        assert_equal allowed.include?(capability),
          workspaces(:acme).capability?(user, capability),
          "expected #{role} / #{capability} to be #{allowed.include?(capability)}"
      end
    end
  end

  test "non-member has no capabilities" do
    CAPABILITIES.each do |capability|
      assert_not workspaces(:acme).capability?(users(:outsider), capability)
    end
  end

  test "role_for returns the membership role" do
    assert_equal "owner", workspaces(:acme).role_for(users(:owner))
    assert_nil workspaces(:acme).role_for(users(:outsider))
  end
end

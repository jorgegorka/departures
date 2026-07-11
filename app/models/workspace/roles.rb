module Workspace::Roles
  extend ActiveSupport::Concern

  ROLE_CAPABILITIES = {
    "owner"     => %w[ send manage_api_keys manage_domains manage_templates manage_webhooks manage_members view_audit_log ],
    "member"    => %w[ send manage_api_keys manage_domains manage_templates manage_webhooks ],
    "sender"    => %w[ send ],
    "api_keys"  => %w[ manage_api_keys ],
    "domains"   => %w[ manage_domains ],
    "read_only" => %w[]
  }.freeze

  def capability?(user, capability)
    ROLE_CAPABILITIES.fetch(role_for(user), []).include?(capability.to_s)
  end

  def role_for(user)
    memberships.find_by(user: user)&.role
  end
end

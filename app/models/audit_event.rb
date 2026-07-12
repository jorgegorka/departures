class AuditEvent < ApplicationRecord
  ACTIONS = %w[
    api_key.issued api_key.revoked api_key.rotated
    invitation.created invitation.accepted
    domain.created domain.verified domain.destroyed
    source.created source.updated
    webhook_endpoint.created webhook_endpoint.updated webhook_endpoint.destroyed
    suppression.created suppression.destroyed
    two_factor.enabled two_factor.disabled
    two_factor.recovery_codes_regenerated two_factor.recovery_code_redeemed
    workspace.two_factor_required workspace.two_factor_requirement_removed
    session.revoked session.bulk_revoked
  ].freeze

  belongs_to :workspace, optional: true
  belongs_to :user, optional: true
  belongs_to :subject, polymorphic: true, optional: true

  validates :action, inclusion: { in: ACTIONS }

  scope :reverse_chronologically, -> { order(created_at: :desc, id: :desc) }
  scope :preloaded, -> { includes(:user) }
  scope :indexed_by, ->(group) do
    case group
    when "api_keys" then where("action LIKE 'api_key.%'")
    when "members" then where("action LIKE 'invitation.%'")
    when "sending" then where("action LIKE 'domain.%' OR action LIKE 'source.%' OR action LIKE 'suppression.%' OR action LIKE 'webhook_endpoint.%'")
    when "security" then where("action LIKE 'two_factor.%' OR action LIKE 'session.%' OR action LIKE 'workspace.%'")
    else all
    end
  end
  scope :in_time_range, ->(range) do
    case range
    when "24h" then where(created_at: 24.hours.ago..)
    when "7d" then where(created_at: 7.days.ago..)
    when "30d" then where(created_at: 30.days.ago..)
    else all
    end
  end

  class << self
    def record(action, subject: nil, metadata: {}, workspace: Current.workspace, user: Current.user)
      create!(action: action, subject: subject, metadata: metadata, workspace: workspace, user: user, ip: Current.ip)
    end

    def prune
      where(created_at: ...180.days.ago).in_batches.delete_all
    end
  end
end

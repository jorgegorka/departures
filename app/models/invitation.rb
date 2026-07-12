class Invitation < ApplicationRecord
  belongs_to :workspace
  belongs_to :invited_by, class_name: "User", default: -> { Current.user }

  scope :pending, -> { where(accepted_at: nil).where(expires_at: Time.current..) }
  scope :expired, -> { where(accepted_at: nil).where(expires_at: ...Time.current) }

  validates :email, presence: true
  validates :role, inclusion: { in: Workspace::Roles::ROLE_CAPABILITIES.keys }

  before_create :generate_token, :set_expiry

  attr_reader :token

  class << self
    def find_by_token(token)
      pending.find_by(token_digest: Digest::SHA256.hexdigest(token.to_s))
    end

    def prune_expired
      expired.in_batches.delete_all
    end
  end

  def accept(user:)
    transaction do
      workspace.memberships.find_or_create_by!(user: user) { |membership| membership.role = role }
      update! accepted_at: Time.current
      AuditEvent.record("invitation.accepted", subject: self, metadata: { email: email, role: role }, workspace: workspace, user: user)
    end
  end

  def deliver_later
    InvitationMailer.invite(self, token).deliver_later
  end

  private
    def generate_token
      @token = SecureRandom.urlsafe_base64(24)
      self.token_digest = Digest::SHA256.hexdigest(@token)
    end

    def set_expiry
      self.expires_at ||= 7.days.from_now
    end
end

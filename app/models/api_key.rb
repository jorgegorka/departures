class ApiKey < ApplicationRecord
  belongs_to :project
  belongs_to :workspace, default: -> { project.workspace }

  scope :active, -> { where(revoked_at: nil).and(where(expires_at: nil).or(where(expires_at: Time.current..))) }

  validates :prefix, presence: true
  validates :key_hash, presence: true, uniqueness: true

  attr_reader :token

  class << self
    def issue(project:, name: nil, scopes: [], expires_in: nil)
      token = "dp_#{SecureRandom.alphanumeric(48)}"

      create!(project: project, name: name, scopes: scopes, prefix: token.first(12),
        key_hash: digest(token), expires_at: expires_in&.from_now).tap do |api_key|
        api_key.instance_variable_set(:@token, token)
      end
    end

    def authenticate_by_token(bearer)
      if bearer.present?
        active.find_by(key_hash: digest(bearer))
      end
    end

    def digest(token)
      Digest::SHA256.hexdigest(token)
    end
  end

  def revoked?
    revoked_at.present?
  end

  def expired?
    expires_at.present? && expires_at.past?
  end

  def active?
    !revoked? && !expired?
  end

  def revoke
    unless revoked?
      update! revoked_at: Time.current
    end
  end

  def rotate
    transaction do
      revoke
      self.class.issue(project: project, name: name, scopes: scopes)
    end
  end

  def allows?(scope)
    scopes.include?(scope.to_s)
  end

  def touch_usage(ip:, user_agent:)
    if last_used_at.nil? || last_used_at < 1.minute.ago
      update_columns(last_used_at: Time.current, last_used_ip: ip, last_used_user_agent: user_agent)
    end
  end
end

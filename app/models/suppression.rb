class Suppression < ApplicationRecord
  belongs_to :project
  belongs_to :workspace, default: -> { project.workspace }

  scope :active, -> { where(expires_at: nil).or(where(expires_at: Time.current..)) }

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, presence: true, uniqueness: { scope: :project_id }
  validates :reason, presence: true

  class << self
    def covers?(project, addresses)
      normalized = Array(addresses).map { |address| address.to_s.strip.downcase }
      active.where(project: project, email: normalized).pluck(:email)
    end
  end
end

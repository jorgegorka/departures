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

    # Create-or-reactivate: the unique (project_id, email) index also holds
    # expired rows, so a bounce for a lapsed address must revive the row.
    def record(project, address, reason:)
      suppression = find_or_initialize_by(project: project, email: address)
      suppression.update!(reason: reason, expires_at: nil)
      suppression
    rescue ActiveRecord::RecordNotUnique
      # A concurrent worker inserted between our lookup and insert — the row
      # now exists, so the retry takes the update path.
      retry
    end
  end
end

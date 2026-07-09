class Suppression < ApplicationRecord
  belongs_to :project
  belongs_to :workspace, default: -> { project.workspace }

  scope :active, -> { where(expires_at: nil).or(where(expires_at: Time.current..)) }

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, presence: true, uniqueness: { scope: :project_id }
  validates :reason, presence: true

  class << self
    def covers?(project, addresses)
      normalized = Array(addresses).map { |address| normalize_value_for(:email, address.to_s) }
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

    def to_csv
      CSV.generate(headers: true) do |csv|
        csv << %w[ email reason expires_at created_at ]
        find_each do |suppression|
          csv << [ csv_safe(suppression.email), csv_safe(suppression.reason), suppression.expires_at&.iso8601,
            suppression.created_at.iso8601 ]
        end
      end
    end

    private
      def csv_safe(value)
        text = value.to_s
        if text.match?(/\A[=+\-@\t\r]/)
          "'#{text}"
        else
          text
        end
      end
  end
end

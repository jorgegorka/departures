class Project < ApplicationRecord
  include Archivable

  belongs_to :workspace
  # emails must be destroyed before sources and api_keys: emails.source_id is a
  # non-null FK (no nullify possible), and destroying an api_key only nullifies
  # its emails, so any remaining emails would trip the sources FK first.
  has_many :emails, dependent: :destroy
  has_many :sources, dependent: :destroy
  has_many :api_keys, dependent: :destroy
  has_many :suppressions, dependent: :destroy
  has_many :domains, dependent: :destroy

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: { scope: :workspace_id }

  before_validation :assign_slug, on: :create

  def deletable?
    archived? && emails.none?
  end

  def metrics_for(range)
    Project::Metrics.new(self, range: range.to_s)
  end

  private
    def assign_slug
      self.slug ||= name&.parameterize
    end
end

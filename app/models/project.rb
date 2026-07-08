class Project < ApplicationRecord
  include Archivable

  belongs_to :workspace
  has_many :sources, dependent: :destroy
  has_many :api_keys, dependent: :destroy
  has_many :emails, dependent: :destroy
  has_many :suppressions, dependent: :destroy

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: { scope: :workspace_id }

  before_validation :assign_slug, on: :create

  def deletable?
    archived? && emails.none?
  end

  def default_environment
    "production"
  end

  private
    def assign_slug
      self.slug ||= name&.parameterize
    end
end

class Workspace < ApplicationRecord
  include Roles

  belongs_to :owner, class_name: "User", default: -> { Current.user }

  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :projects, dependent: :destroy

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true

  before_validation :assign_slug, on: :create

  class << self
    def create_with_owner(owner:, **attributes)
      transaction do
        workspace = create!(owner: owner, **attributes)
        workspace.memberships.create!(user: owner, role: "owner")
        workspace
      end
    end
  end

  private
    def assign_slug
      self.slug ||= name&.parameterize
    end
end

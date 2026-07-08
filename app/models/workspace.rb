class Workspace < ApplicationRecord
  include Roles

  belongs_to :owner, class_name: "User", default: -> { Current.user }

  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :projects, dependent: :destroy
  has_many :invitations, dependent: :destroy

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true

  before_validation :assign_slug, on: :create

  class << self
    def create_with_owner(owner:, **attributes)
      workspace = new(owner: owner, **attributes)

      transaction do
        workspace.save && workspace.memberships.create!(user: owner, role: "owner")
      end

      workspace
    end
  end

  private
    def assign_slug
      return if slug.present?

      base = name&.parameterize
      return if base.blank?

      self.slug = base
      suffix = 2
      while Workspace.exists?(slug:)
        self.slug = "#{base}-#{suffix}"
        suffix += 1
      end
    end
end

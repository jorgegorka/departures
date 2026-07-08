class Workspace < ApplicationRecord
  include Roles

  belongs_to :owner, class_name: "User", default: -> { Current.user }

  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true

  before_validation :assign_slug, on: :create

  private
    def assign_slug
      self.slug ||= name&.parameterize
    end
end

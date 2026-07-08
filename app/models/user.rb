class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :memberships, dependent: :destroy
  has_many :workspaces, through: :memberships

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :email_address, presence: true, uniqueness: true

  class << self
    def registration_open?
      none? || ENV["OPEN_REGISTRATION"].present?
    end

    def create_owner(attributes)
      user = new(attributes)

      transaction do
        if user.save
          Workspace.create_with_owner(owner: user, name: default_workspace_name_for(user))
        end
      end

      user
    end

    private
      def default_workspace_name_for(user)
        "#{user.email_address.split("@").first.capitalize}'s Workspace"
      end
  end
end

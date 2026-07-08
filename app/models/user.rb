class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :memberships, dependent: :destroy
  has_many :workspaces, through: :memberships

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  class << self
    def registration_open?
      none? || ENV["OPEN_REGISTRATION"].present?
    end

    def create_owner(attributes)
      transaction do
        user = create!(attributes)
        Workspace.create_with_owner(owner: user, name: default_workspace_name_for(user))
        user
      end
    end

    private
      def default_workspace_name_for(user)
        "#{user.email_address.split("@").first.capitalize}'s Workspace"
      end
  end
end

class Membership < ApplicationRecord
  belongs_to :workspace
  belongs_to :user

  validates :role, inclusion: { in: Workspace::Roles::ROLE_CAPABILITIES.keys }
  validates :user_id, uniqueness: { scope: :workspace_id }
end

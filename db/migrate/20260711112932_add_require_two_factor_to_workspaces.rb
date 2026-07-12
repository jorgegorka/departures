class AddRequireTwoFactorToWorkspaces < ActiveRecord::Migration[8.1]
  def change
    add_column :workspaces, :require_two_factor, :boolean, default: false, null: false
  end
end

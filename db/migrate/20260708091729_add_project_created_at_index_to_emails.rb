class AddProjectCreatedAtIndexToEmails < ActiveRecord::Migration[8.1]
  def change
    add_index :emails, [ :project_id, :created_at ]
  end
end

class AddBounceTypeToEmails < ActiveRecord::Migration[8.1]
  def change
    add_column :emails, :bounce_type, :string
    add_index :emails, [ :project_id, :bounce_type ]
  end
end

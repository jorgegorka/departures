class CreateWorkspaces < ActiveRecord::Migration[8.1]
  def change
    create_table :workspaces do |t|
      t.string :name, null: false
      t.string :slug, null: false, index: { unique: true }
      t.references :owner, null: false, foreign_key: { to_table: :users }
      t.datetime :setup_started_at
      t.datetime :onboarded_at
      t.timestamps
    end
  end
end

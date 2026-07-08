class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.references :workspace, null: false, foreign_key: true
      t.string :name, null: false
      t.string :slug, null: false
      t.string :default_environment, null: false, default: "production"
      t.datetime :archived_at
      t.timestamps
      t.index [ :workspace_id, :slug ], unique: true
    end
  end
end

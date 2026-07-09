class CreateSuppressions < ActiveRecord::Migration[8.1]
  def change
    create_table :suppressions do |t|
      t.references :project, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.string :email, null: false
      t.string :reason, null: false
      t.datetime :expires_at
      t.timestamps
      t.index [ :project_id, :email ], unique: true
    end
  end
end

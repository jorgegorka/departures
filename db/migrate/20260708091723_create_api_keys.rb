class CreateApiKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :api_keys do |t|
      t.references :project, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.string :name
      t.string :prefix, null: false
      t.string :key_hash, null: false, index: { unique: true }
      t.json :scopes, null: false, default: []
      t.datetime :expires_at
      t.datetime :revoked_at
      t.datetime :last_used_at
      t.string :last_used_ip
      t.string :last_used_user_agent
      t.timestamps
    end
  end
end

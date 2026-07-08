class CreateSources < ActiveRecord::Migration[8.1]
  def change
    create_table :sources do |t|
      t.references :project, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.string :name
      t.string :environment, null: false, default: "production"
      t.string :region, null: false, default: "us-east-1"
      t.string :configuration_set
      t.string :default_from
      t.string :aws_access_key_id
      t.string :aws_secret_access_key
      t.string :webhook_token, index: { unique: true }
      t.integer :retention_days, null: false, default: 30
      t.json :last_quota
      t.datetime :last_quota_checked_at
      t.timestamps
      t.index [ :project_id, :environment ], unique: true
    end
  end
end

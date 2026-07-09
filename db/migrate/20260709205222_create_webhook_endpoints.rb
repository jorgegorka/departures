class CreateWebhookEndpoints < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_endpoints do |t|
      t.references :project, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.string :url, null: false
      t.string :secret
      t.json :events, default: [], null: false
      t.boolean :active, default: true, null: false

      t.timestamps
    end
  end
end

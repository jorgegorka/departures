class CreateWebhookLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_logs do |t|
      t.references :source, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.string :message_type
      t.json :payload, default: {}, null: false
      t.string :status, default: "received", null: false
      t.string :error
      t.datetime :processed_at
      t.timestamps
    end

    add_index :webhook_logs, [ :source_id, :created_at ]
  end
end

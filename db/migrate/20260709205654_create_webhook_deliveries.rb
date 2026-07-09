class CreateWebhookDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_deliveries do |t|
      t.references :webhook_endpoint, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.references :email, foreign_key: { on_delete: :nullify }
      t.string :event_type, null: false
      t.json :payload, default: {}, null: false
      t.string :status, default: "pending", null: false
      t.integer :attempts, default: 0, null: false
      t.integer :http_status
      t.integer :latency_ms
      t.string :response_body
      t.datetime :last_attempted_at

      t.timestamps
    end

    add_index :webhook_deliveries, %i[ webhook_endpoint_id created_at ]
  end
end

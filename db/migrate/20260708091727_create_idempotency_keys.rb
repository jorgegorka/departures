class CreateIdempotencyKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :idempotency_keys do |t|
      t.references :api_key, null: false, foreign_key: true
      t.references :email, null: false, foreign_key: true
      t.string :key, null: false
      t.string :fingerprint, null: false
      t.datetime :expires_at, null: false
      t.timestamps
      t.index [ :api_key_id, :key ], unique: true
    end
  end
end

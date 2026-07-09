class CreateEmailEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :email_events do |t|
      t.references :email, null: false, foreign_key: true
      t.string :event_type, null: false
      t.string :ses_message_id
      t.string :recipient
      t.string :url
      t.string :user_agent
      t.string :ip
      t.json :payload, default: {}, null: false
      t.datetime :occurred_at, null: false
      t.timestamps
    end

    add_index :email_events, [ :email_id, :occurred_at ]
  end
end

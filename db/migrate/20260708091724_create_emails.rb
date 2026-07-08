class CreateEmails < ActiveRecord::Migration[8.1]
  def change
    create_table :emails do |t|
      t.references :project, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.references :source, null: false, foreign_key: true
      t.references :api_key, foreign_key: true
      t.string :public_id, null: false, index: { unique: true }
      t.string :status, null: false, default: "queued"
      t.string :from, null: false
      t.string :subject
      t.text :html_body
      t.text :text_body
      t.string :ses_message_id, index: true
      t.json :headers, null: false, default: {}
      t.json :tags, null: false, default: {}
      t.string :mime_path
      t.integer :mime_size
      t.string :failure_reason
      t.timestamps
      t.index [ :project_id, :status, :created_at ]
    end
  end
end

class CreateEmailAttachments < ActiveRecord::Migration[8.1]
  def change
    create_table :email_attachments do |t|
      t.references :email, null: false, foreign_key: true
      t.string :filename, null: false
      t.string :content_type
      t.integer :byte_size, null: false, default: 0
      t.timestamps
    end
  end
end

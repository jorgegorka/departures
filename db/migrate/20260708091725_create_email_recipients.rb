class CreateEmailRecipients < ActiveRecord::Migration[8.1]
  def change
    create_table :email_recipients do |t|
      t.references :email, null: false, foreign_key: true
      t.string :kind, null: false, default: "to"
      t.string :address, null: false, index: true
      t.timestamps
    end
  end
end

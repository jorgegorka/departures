class AddResentAtToEmails < ActiveRecord::Migration[8.1]
  def change
    add_column :emails, :resent_at, :datetime
  end
end

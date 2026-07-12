class AddTwoFactorToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :otp_secret, :string
    add_column :users, :otp_enabled_at, :datetime
    add_column :users, :otp_consumed_timestep, :integer
    add_column :users, :otp_recovery_codes, :json, default: [], null: false
  end
end

class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  class << self
    def registration_open?
      none? || ENV["OPEN_REGISTRATION"].present?
    end
  end
end

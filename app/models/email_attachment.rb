class EmailAttachment < ApplicationRecord
  belongs_to :email

  validates :filename, presence: true
  validates :byte_size, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end

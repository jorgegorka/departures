class EmailRecipient < ApplicationRecord
  belongs_to :email

  enum :kind, %w[ to cc bcc ].index_by(&:itself), default: "to", prefix: true

  validates :address, presence: true
end

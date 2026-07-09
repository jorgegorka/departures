class EmailEvent < ApplicationRecord
  belongs_to :email

  validates :event_type, presence: true
  validates :occurred_at, presence: true

  scope :reverse_chronologically, -> { order(occurred_at: :desc, id: :desc) }
end

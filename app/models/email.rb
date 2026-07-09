class Email < ApplicationRecord
  include Statuses, Deliverable

  belongs_to :project
  belongs_to :workspace, default: -> { project.workspace }
  belongs_to :source
  belongs_to :api_key, optional: true

  has_many :recipients, class_name: "EmailRecipient", dependent: :destroy
  has_many :attachments, class_name: "EmailAttachment", dependent: :destroy
  has_many :idempotency_keys, dependent: :destroy

  validates :from, presence: true

  before_create :assign_public_id

  private
    def assign_public_id
      self.public_id ||= "em_#{SecureRandom.alphanumeric(24)}"
    end
end

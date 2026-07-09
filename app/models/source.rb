class Source < ApplicationRecord
  belongs_to :project
  belongs_to :workspace, default: -> { project.workspace }

  has_many :emails
  has_many :webhook_logs, dependent: :destroy

  has_secure_token :webhook_token

  encrypts :aws_access_key_id, :aws_secret_access_key

  validates :environment, presence: true, uniqueness: { scope: :project_id }
  validates :region, presence: true
  validates :retention_days, numericality: { only_integer: true, greater_than: 0 }

  attr_writer :ses_client

  def ses_client
    @ses_client ||= Aws::SESV2::Client.new(region: region,
      credentials: Aws::Credentials.new(aws_access_key_id, aws_secret_access_key))
  end
end

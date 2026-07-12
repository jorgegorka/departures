class Domain < ApplicationRecord
  NAME_FORMAT = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/

  belongs_to :project
  belongs_to :workspace, default: -> { project.workspace }

  enum :status, %w[ pending verified failed ].index_by(&:itself), default: "pending", validate: true

  normalizes :name, with: ->(name) { name.strip.downcase }

  validates :name, presence: true, uniqueness: { scope: :project_id },
    format: { with: NAME_FORMAT, message: "is not a valid domain name" }

  attr_writer :ses_client

  def self.verifies?(project, address)
    host = EmailAddress.address_part(address)&.split("@")&.last&.downcase
    return false if host.blank?

    project.domains.verified.pluck(:name).any? do |name|
      host == name || host.end_with?(".#{name}")
    end
  end

  def provision
    response = ses_client.create_email_identity(email_identity: name)
    update!(dkim_tokens: Array(response.dkim_attributes&.tokens))
    true
  rescue Aws::SESV2::Errors::AlreadyExistsException
    check
  rescue Aws::SESV2::Errors::ServiceError, Seahorse::Client::NetworkingError
    update!(status: "failed")
    false
  end

  def check
    previously_verified = verified?
    response = ses_client.get_email_identity(email_identity: name)
    update!(status: response.verified_for_sending_status ? "verified" : "pending",
      dkim_tokens: Array(response.dkim_attributes&.tokens).presence || dkim_tokens,
      last_checked_at: Time.current)
    if verified? && !previously_verified
      AuditEvent.record("domain.verified", subject: self, metadata: { name: name }, workspace: workspace)
    end
    verified?
  rescue Aws::SESV2::Errors::NotFoundException
    update!(status: "failed", last_checked_at: Time.current)
    false
  rescue Aws::SESV2::Errors::ServiceError, Seahorse::Client::NetworkingError
    false
  end

  def decommission
    ses_client.delete_email_identity(email_identity: name)
    destroy
  rescue Aws::SESV2::Errors::ServiceError, Seahorse::Client::NetworkingError
    destroy
  end

  def dkim_records
    dkim_tokens.map do |token|
      { name: "#{token}._domainkey.#{name}", value: "#{token}.dkim.amazonses.com" }
    end
  end

  def ses_client
    @ses_client ||= source.ses_client
  end

  private
    def source
      project.sources.order(:id).first
    end
end

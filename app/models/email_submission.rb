class EmailSubmission
  include ActiveModel::Model

  MAX_ADDRESS_LENGTH = 1000
  MAX_TOTAL_RECIPIENTS = 50
  MAX_ATTACHMENT_COUNT = 25
  MAX_ATTACHMENT_BYTES = 30.megabytes

  RESERVED_HEADERS = %w[
    from to cc bcc subject date message-id return-path received mime-version
    content-type content-transfer-encoding dkim-signature x-departures-id
  ].freeze

  attr_accessor :project, :source, :api_key, :from, :subject, :template_id, :html, :text
  attr_reader :to, :cc, :bcc, :headers, :tags, :attachments, :variables

  validates :project, :source, presence: true

  validate :validate_from,
    :validate_recipient_lists,
    :validate_total_recipients,
    :validate_template,
    :validate_subject_xor_template,
    :validate_body_presence,
    :validate_attachments,
    :validate_reserved_headers,
    :validate_header_and_tag_values,
    :validate_suppressed_recipients,
    :validate_guardrails

  def initialize(attributes = {})
    @to, @cc, @bcc = [], [], []
    @headers, @tags = {}, {}
    @attachments = []
    @variables = {}
    super
  end

  def to=(addresses)
    @to = Array(addresses).map(&:to_s)
  end

  def cc=(addresses)
    @cc = Array(addresses).map(&:to_s)
  end

  def bcc=(addresses)
    @bcc = Array(addresses).map(&:to_s)
  end

  def headers=(value)
    @headers = (value || {}).to_h.transform_keys(&:to_s)
  end

  def tags=(value)
    @tags = (value || {}).to_h.transform_keys(&:to_s)
  end

  def attachments=(value)
    @attachments = Array(value).map { |attachment| attachment.to_h.symbolize_keys }
  end

  def variables=(value)
    @variables = (value || {}).to_h.transform_keys(&:to_s)
  end

  def save
    if valid?
      create_email
    else
      false
    end
  rescue ActiveRecord::RecordInvalid => invalid
    errors.merge!(invalid.record.errors)
    false
  end

  private
    def create_email
      Email.transaction do
        email = Email.create!(project: project, source: source, api_key: api_key,
          from: from, subject: effective_subject, html_body: effective_html, text_body: effective_text,
          headers: headers, tags: tags)

        { "to" => to, "cc" => cc, "bcc" => bcc }.each do |kind, addresses|
          addresses.each do |address|
            email.recipients.create!(kind: kind, address: address)
          end
        end

        attachments.each do |attachment|
          email.attachments.create!(filename: attachment[:filename],
            content_type: attachment[:content_type], byte_size: decoded_size(attachment))
        end

        Email::MimeStore.write(email, Email::MimeBuilder.new(email, attachments: attachments).to_eml)
        email.deliver_later

        email
      end
    end

    def validate_from
      if from.blank?
        errors.add(:from, "is required")
      elsif !valid_address?(from)
        errors.add(:from, "is not a valid email address")
      end
    end

    def validate_recipient_lists
      if to.empty?
        errors.add(:to, "must contain at least one recipient")
      end

      { to: to, cc: cc, bcc: bcc }.each do |field, addresses|
        addresses.each do |address|
          unless valid_address?(address)
            errors.add(field, "contains an invalid address: #{address.truncate(60)}")
          end
        end
      end
    end

    def validate_total_recipients
      if all_recipients.size > MAX_TOTAL_RECIPIENTS
        errors.add(:base, "cannot exceed #{MAX_TOTAL_RECIPIENTS} total recipients across to, cc, and bcc")
      end
    end

    def validate_template
      if template_id.present? && template.nil?
        errors.add(:template_id, "does not match any template")
      end
    end

    def validate_subject_xor_template
      if subject.present? && template_id.present?
        errors.add(:base, "provide either subject or template_id, not both")
      elsif subject.blank? && template_id.blank?
        errors.add(:subject, "is required unless template_id is given")
      end
    end

    def validate_body_presence
      if template_id.blank? && html.blank? && text.blank?
        errors.add(:base, "html or text body is required")
      end
    end

    def validate_attachments
      if attachments.size > MAX_ATTACHMENT_COUNT
        errors.add(:attachments, "cannot exceed #{MAX_ATTACHMENT_COUNT} files")
      end

      attachments.each do |attachment|
        if attachment[:filename].blank?
          errors.add(:attachments, "must each have a filename")
        end

        unless valid_base64?(attachment[:content])
          errors.add(:attachments, "#{attachment[:filename]} content is not valid base64")
        end
      end

      if attachments.sum { |attachment| decoded_size(attachment) } > MAX_ATTACHMENT_BYTES
        errors.add(:attachments, "cannot exceed 30 MB in total")
      end
    end

    def validate_reserved_headers
      headers.each_key do |name|
        if RESERVED_HEADERS.include?(name.downcase)
          errors.add(:headers, "#{name} is a reserved header")
        end
      end
    end

    def validate_header_and_tag_values
      { headers: headers, tags: tags }.each do |field, pairs|
        pairs.each_key do |name|
          if name.match?(/[[:cntrl:]]/)
            errors.add(field, "names must not contain control characters")
          elsif name.length > MAX_ADDRESS_LENGTH
            errors.add(field, "names cannot exceed #{MAX_ADDRESS_LENGTH} characters")
          end
        end

        pairs.each_value do |value|
          if !value.is_a?(String)
            errors.add(field, "values must be strings")
          elsif value.match?(/[[:cntrl:]]/)
            errors.add(field, "values must not contain control characters")
          elsif value.length > MAX_ADDRESS_LENGTH
            errors.add(field, "values cannot exceed #{MAX_ADDRESS_LENGTH} characters")
          end
        end
      end
    end

    def validate_suppressed_recipients
      if project
        suppressed = Suppression.covers?(project, bare_recipients)

        if suppressed.any?
          errors.add(:base, "recipients are suppressed: #{suppressed.join(", ")}")
        end
      end
    end

    def validate_guardrails
      return if project.nil? || source.nil?

      unless from_domain_verified?
        errors.add(:from, "domain is not verified")
      end

      unless quota_fresh?
        errors.add(:base, "sending quota information is stale")
      end

      if complaint_breaker_tripped?
        errors.add(:base, "sending is paused due to complaint rate")
      end
    end

    def template
      if project && template_id.present?
        @template ||= project.templates.find_by(slug: template_id.to_s.downcase) ||
          project.templates.find_by(id: template_id)
      end
    end

    def rendered_template
      @rendered_template ||= template&.render(variables)
    end

    def effective_subject
      template ? rendered_template.subject : subject
    end

    def effective_html
      template ? rendered_template.html : html
    end

    def effective_text
      template ? rendered_template.text : text
    end

    def all_recipients
      to + cc + bcc
    end

    def bare_recipients
      all_recipients.filter_map { |address| EmailAddress.address_part(address) }
    end

    def valid_address?(address)
      address.length <= MAX_ADDRESS_LENGTH && EmailAddress.valid?(address)
    end

    def decoded_size(attachment)
      (attachment[:content].to_s.length * 3) / 4
    end

    def valid_base64?(content)
      Base64.strict_decode64(content.to_s)
      true
    rescue ArgumentError
      false
    end

    def from_domain_verified?
      Domain.verifies?(project, from)
    end

    def quota_fresh?
      if source.quota_stale?
        source.sync_quota
      end
      source.quota_fresh?
    end

    def complaint_breaker_tripped?
      source.complaint_rate_exceeded?
    end
end

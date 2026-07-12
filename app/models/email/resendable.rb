module Email::Resendable
  extend ActiveSupport::Concern

  class_methods do
    def retry_soft_bounces(limit: 100)
      soft_bounced.where(resent_at: nil).reverse_chronologically.limit(limit).to_a.count { |email| email.resend }
    end
  end

  # Rebuilds a fresh submission from the stored fields and the archived MIME
  # (attachment bytes only exist inside the .eml), so the copy runs the full
  # validation matrix — including suppression — before entering the queue.
  # Stamps resent_at on success so a bulk retry never re-sends the same original.
  def resend
    if resendable?
      transaction do
        resent = EmailSubmission.new(resubmission_attributes).save
        if resent
          update!(resent_at: Time.current)
        end
        resent
      end
    else
      false
    end
  end

  private
    def resendable?
      attachments.none? || mime_path.present?
    end

    def resubmission_attributes
      { project: project, source: source, from: from, subject: subject,
        html: html_body, text: text_body, **addresses_by_kind,
        headers: headers, tags: tags.merge("resent_from" => public_id),
        attachments: archived_attachments }
    end

    def archived_attachments
      if attachments.none?
        []
      else
        Mail.new(Email::MimeStore.read(self)).attachments.map do |part|
          { filename: part.filename, content_type: part.mime_type,
            content: Base64.strict_encode64(part.body.decoded) }
        end
      end
    end
end

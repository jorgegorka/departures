class Email::MimeBuilder
  attr_reader :email, :attachments

  def initialize(email, attachments: [])
    @email = email
    @attachments = attachments
  end

  def to_eml
    mail.encoded
  end

  private
    def mail
      @mail ||= Mail.new.tap do |message|
        message.from = email.from
        message.to = addresses_for("to")

        if addresses_for("cc").any?
          message.cc = addresses_for("cc")
        end

        message.subject = email.subject
        message.message_id = "#{email.public_id}@#{from_domain}"
        message.header["X-Departures-Id"] = email.public_id
        email.headers.each { |name, value| message.header[name] = value }
        add_body(message)
        add_attachments(message)
      end
    end

    def addresses_for(kind)
      email.recipients.where(kind: kind).order(:id).pluck(:address)
    end

    def from_domain
      email.from.to_s.split("@").last
    end

    def add_body(message)
      if email.html_body.present? && email.text_body.present?
        message.add_part(alternative_part)
      elsif email.html_body.present?
        message.add_part(html_part)
      else
        message.add_part(text_part)
      end
    end

    def alternative_part
      Mail::Part.new(content_type: "multipart/alternative").tap do |alternative|
        alternative.add_part(text_part)
        alternative.add_part(html_part)
      end
    end

    def text_part
      Mail::Part.new(body: email.text_body, content_type: "text/plain; charset=UTF-8")
    end

    def html_part
      Mail::Part.new(body: email.html_body, content_type: "text/html; charset=UTF-8")
    end

    def add_attachments(message)
      attachments.each do |attachment|
        message.attachments[attachment[:filename]] = {
          mime_type: attachment[:content_type].presence || "application/octet-stream",
          content: Base64.decode64(attachment[:content].to_s) }
      end
    end
end

require "test_helper"

class Email::MimeBuilderTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    @email = Email.create!(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", subject: "Welcome", html_body: "<p>Hi</p>", text_body: "Hi",
      headers: { "X-Campaign" => "onboarding" })
    @email.recipients.create!(kind: "to", address: "user@example.com")
    @email.recipients.create!(kind: "cc", address: "copy@example.com")
    @email.recipients.create!(kind: "bcc", address: "hidden@example.com")
  end

  test "to_eml returns a parseable MIME string with envelope headers" do
    mail = parsed

    assert_equal [ "hello@acme.com" ], mail.from
    assert_equal [ "user@example.com" ], mail.to
    assert_equal [ "copy@example.com" ], mail.cc
    assert_equal "Welcome", mail.subject
  end

  test "bcc recipients never appear anywhere in the MIME" do
    eml = Email::MimeBuilder.new(@email).to_eml

    assert_not_includes eml, "hidden@example.com"
    assert_not_includes eml.downcase, "\nbcc:"
  end

  test "identification headers are set" do
    mail = parsed

    assert_equal @email.public_id, mail.header["X-Departures-Id"].value
    assert_equal "#{@email.public_id}@acme.com", mail.message_id
  end

  test "a display-name from preserves the display name and derives the Message-ID domain from the addr-spec" do
    @email.update!(from: "Acme Support <hello@acme.com>")

    mail = parsed

    assert_equal [ "hello@acme.com" ], mail.from
    assert_equal [ "Acme Support" ], mail[:from].display_names
    assert_equal "#{@email.public_id}@acme.com", mail.message_id
  end

  test "custom headers pass through" do
    assert_equal "onboarding", parsed.header["X-Campaign"].value
  end

  test "html and text nest as multipart/alternative with text before html" do
    alternative = parsed.parts.first

    assert alternative.content_type.start_with?("multipart/alternative")
    assert_equal "text/plain", alternative.parts.first.mime_type
    assert_equal "text/html", alternative.parts.second.mime_type
    assert_equal "Hi", alternative.parts.first.decoded
    assert_equal "<p>Hi</p>", alternative.parts.second.decoded
  end

  test "html-only email carries a single html part" do
    @email.update!(text_body: nil)

    mail = parsed
    assert_equal "text/html", mail.parts.first.mime_type
    assert(mail.parts.none? { |part| part.mime_type == "text/plain" })
  end

  test "text-only email carries a single text part" do
    @email.update!(html_body: nil)

    assert_equal "text/plain", parsed.parts.first.mime_type
  end

  test "attachments encode and round-trip, nested beside the alternative part" do
    content = Base64.strict_encode64("Hello PDF bytes")
    mail = parsed(attachments: [ { filename: "report.pdf", content_type: "application/pdf", content: content } ])

    attachment = mail.attachments["report.pdf"]
    assert_equal "application/pdf", attachment.mime_type
    assert_equal "Hello PDF bytes", attachment.decoded
    assert mail.parts.first.content_type.start_with?("multipart/alternative"),
      "alternative part must stay nested as the first sibling of the attachment"
  end

  test "attachments without a content type fall back to octet-stream" do
    content = Base64.strict_encode64("bytes")
    mail = parsed(attachments: [ { filename: "blob.bin", content_type: nil, content: content } ])

    assert_equal "application/octet-stream", mail.attachments["blob.bin"].mime_type
  end

  private
    def parsed(attachments: [])
      Mail.read_from_string(Email::MimeBuilder.new(@email, attachments: attachments).to_eml)
    end
end

require "test_helper"

class EmailSubmissionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Current.session = sessions(:owner)
  end

  def valid_attributes(**overrides)
    { project: projects(:acme_default), source: sources(:acme_production), api_key: api_keys(:acme_full),
      from: "hello@acme.com", to: [ "user@example.com" ], subject: "Hi", html: "<p>Hi</p>" }.merge(overrides)
  end

  def submission(**overrides)
    EmailSubmission.new(valid_attributes(**overrides))
  end

  test "a valid submission saves an email with recipients and attachment metadata" do
    content = Base64.strict_encode64("PDF BYTES")
    subject = submission(cc: [ "cc@example.com" ], bcc: [ "bcc@example.com" ],
      headers: { "X-Campaign" => "welcome" }, tags: { "team" => "growth" },
      attachments: [ { filename: "a.pdf", content_type: "application/pdf", content: content } ])

    email = nil
    assert_difference -> { Email.count } => +1, -> { EmailRecipient.count } => +3, -> { EmailAttachment.count } => +1 do
      email = subject.save
    end

    assert_kind_of Email, email
    assert email.persisted?
    assert_equal "queued", email.status
    assert_equal "hello@acme.com", email.from
    assert_equal [ "user@example.com" ], email.recipients.kind_to.pluck(:address)
    assert_equal [ "cc@example.com" ], email.recipients.kind_cc.pluck(:address)
    assert_equal [ "bcc@example.com" ], email.recipients.kind_bcc.pluck(:address)
    assert_equal({ "X-Campaign" => "welcome" }, email.headers)
    assert_equal "a.pdf", email.attachments.sole.filename
    assert_equal (content.length * 3) / 4, email.attachments.sole.byte_size
    assert_equal api_keys(:acme_full), email.api_key
  end

  test "save returns false and persists nothing when invalid" do
    subject = submission(to: [])

    assert_no_difference -> { Email.count } do
      assert_equal false, subject.save
    end
  end

  test "from is required and must be an email address" do
    assert_not submission(from: nil).valid?
    assert_not submission(from: "not-an-email").valid?
  end

  test "at least one to recipient is required" do
    subject = submission(to: [])

    assert_not subject.valid?
    assert subject.errors[:to].any?
  end

  test "recipient addresses must be valid and at most 1000 characters" do
    assert_not submission(to: [ "not-an-email" ]).valid?
    assert_not submission(cc: [ "cc-broken" ]).valid?
    assert_not submission(bcc: [ "bcc-broken" ]).valid?
    assert_not submission(to: [ "#{"a" * 995}@example.com" ]).valid?
    assert submission(to: [ "user@example.com" ]).valid?
  end

  test "total recipients across to, cc, and bcc are capped at 50" do
    addresses = ->(n, tag) { n.times.map { |i| "#{tag}#{i}@example.com" } }
    assert submission(to: addresses.(20, "t"), cc: addresses.(20, "c"), bcc: addresses.(10, "b")).valid?

    subject = submission(to: addresses.(20, "t"), cc: addresses.(20, "c"), bcc: addresses.(11, "b"))
    assert_not subject.valid?
    assert subject.errors[:base].any? { |m| m.include?("50") }
  end

  test "subject XOR template" do
    assert_not submission(subject: nil, template_id: nil).valid?
    assert_not submission(subject: "Hi", template_id: 42).valid?
  end

  test "template_id is rejected until templates are supported (Phase 5)" do
    subject = submission(subject: nil, template_id: 42, html: "<p>Hi</p>")

    assert_not subject.valid?
    assert subject.errors[:template_id].any? { |m| m.include?("not yet supported") }
  end

  test "html or text body is required without a template" do
    assert_not submission(html: nil, text: nil).valid?
    assert submission(html: nil, text: "Hi").valid?
  end

  test "at most 25 attachments" do
    attachments = 26.times.map { |i| { filename: "f#{i}.txt", content: Base64.strict_encode64("x") } }

    subject = submission(attachments: attachments)

    assert_not subject.valid?
    assert subject.errors[:attachments].any?
  end

  test "attachments are capped at 30 MB total decoded size" do
    big = Base64.strict_encode64("x" * 16.megabytes)
    subject = submission(attachments: [
      { filename: "a.bin", content: big }, { filename: "b.bin", content: big }
    ])

    assert_not subject.valid?
    assert subject.errors[:attachments].any? { |m| m.include?("30") }
  end

  test "attachments require a filename" do
    assert_not submission(attachments: [ { content: Base64.strict_encode64("x") } ]).valid?
  end

  test "reserved headers are rejected" do
    %w[ From To Subject Message-ID DKIM-Signature Content-Type X-Departures-Id ].each do |header|
      subject = submission(headers: { header => "value" })

      assert_not subject.valid?, "#{header} should be reserved"
      assert subject.errors[:headers].any?
    end

    assert submission(headers: { "X-Campaign" => "ok" }).valid?
  end

  test "header values with CRLF are rejected" do
    assert_not submission(headers: { "X-Campaign" => "welcome\r\nBcc: victim@example.com" }).valid?
  end

  test "non-string header values are rejected" do
    assert_not submission(headers: { "X-Campaign" => { "nested" => "hash" } }).valid?
    assert_not submission(headers: { "X-Campaign" => 42 }).valid?
  end

  test "over-long header values are rejected" do
    assert_not submission(headers: { "X-Campaign" => "a" * 1001 }).valid?
  end

  test "tag values with CRLF are rejected" do
    assert_not submission(tags: { "team" => "growth\r\nBcc: victim@example.com" }).valid?
  end

  test "non-string tag values are rejected" do
    assert_not submission(tags: { "team" => { "nested" => "hash" } }).valid?
    assert_not submission(tags: { "team" => 42 }).valid?
  end

  test "over-long tag values are rejected" do
    assert_not submission(tags: { "team" => "a" * 1001 }).valid?
  end

  test "suppressed recipients are rejected with their addresses listed" do
    subject = submission(to: [ "user@example.com", "blocked@example.com" ], bcc: [ "temporary@example.com" ])

    assert_not subject.valid?
    message = subject.errors[:base].sole
    assert_includes message, "blocked@example.com"
    assert_includes message, "temporary@example.com"
  end

  test "expired suppressions do not block sends" do
    assert submission(to: [ "lapsed@example.com" ]).valid?
  end

  test "project and source are required" do
    assert_not submission(project: nil).valid?
    assert_not submission(source: nil).valid?
  end

  test "scalar recipients are normalized to arrays for internal callers" do
    assert submission(to: "user@example.com").valid?
  end

  # --- Phase 2: MIME + delivery wiring ---

  test "save stores the MIME and enqueues delivery" do
    submission = delivery_submission

    email = nil
    assert_enqueued_with(job: SendEmailJob) do
      email = submission.save
    end

    assert_equal "queued", email.status
    assert_equal "#{email.project_id}/#{email.public_id}.eml", email.mime_path
    assert Email::MimeStore.root.join(email.mime_path).exist?
    assert_includes Email::MimeStore.read(email), "X-Departures-Id: #{email.public_id}"
  end

  test "request-time attachment bytes reach the stored MIME" do
    submission = delivery_submission(attachments: [
      { filename: "hello.txt", content_type: "text/plain", content: Base64.strict_encode64("Hello!") } ])

    email = submission.save

    parsed = Mail.read_from_string(Email::MimeStore.read(email))
    assert_equal "Hello!", parsed.attachments["hello.txt"].decoded
  end

  test "an invalid submission writes no MIME and enqueues nothing" do
    submission = delivery_submission(to: [])

    assert_no_enqueued_jobs only: SendEmailJob do
      assert_not submission.save
    end
  end

  # --- Phase 1 carry-overs: delivery-safety races ---

  test "save returns false with errors when a validation race raises RecordInvalid" do
    submission = delivery_submission
    invalid_email = Email.new.tap { |email| email.errors.add(:from, "is required") }

    Email.stub :create!, ->(*) { raise ActiveRecord::RecordInvalid.new(invalid_email) } do
      assert_not submission.save
    end

    assert_includes submission.errors.full_messages.join(", "), "From is required"
  end

  # --- Phase 1 carry-overs: input hardening ---

  test "header and tag names reject control characters and oversized names" do
    submission = delivery_submission(headers: { "X-Bad\r\nInjected" => "v" })
    assert_not submission.save
    assert submission.errors[:headers].any? { |message| message.include?("control characters") }

    submission = delivery_submission(tags: { "t" * 1001 => "v" })
    assert_not submission.save
    assert submission.errors[:tags].any? { |message| message.include?("1000") }
  end

  test "attachment content must be valid strict base64" do
    submission = delivery_submission(attachments: [
      { filename: "bad.bin", content_type: "application/octet-stream", content: "not base64!!" } ])

    assert_not submission.save
    assert submission.errors[:attachments].any? { |message| message.include?("base64") }
  end

  test "valid strict base64 attachment content is accepted" do
    submission = delivery_submission(attachments: [
      { filename: "ok.bin", content_type: "application/octet-stream", content: Base64.strict_encode64("ok") } ])

    assert submission.save
  end

  private
    def delivery_submission(**overrides)
      EmailSubmission.new({ project: projects(:acme_default), source: sources(:acme_production),
        from: "hello@acme.com", to: [ "user@example.com" ], subject: "Hi", html: "<p>Hi</p>" }.merge(overrides))
    end
end

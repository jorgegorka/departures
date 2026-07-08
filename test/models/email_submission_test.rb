require "test_helper"

class EmailSubmissionTest < ActiveSupport::TestCase
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
    assert submission(subject: nil, template_id: 42, html: "<p>Hi</p>").valid?
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
end

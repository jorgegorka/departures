require "test_helper"

class Email::ResendableTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Current.session = sessions(:owner)
    @project = projects(:acme_default)
  end

  test "resend queues a copy tagged with the original id" do
    original = submit_email(to: [ "again@example.com" ])

    resent = assert_difference -> { Email.count }, +1 do
      original.resend
    end

    assert_equal "queued", resent.status
    assert_equal original.public_id, resent.tags["resent_from"]
    assert_equal [ "again@example.com" ], resent.recipients.kind_to.pluck(:address)
    assert_equal original.subject, resent.subject
  end

  test "resend enqueues delivery" do
    original = submit_email(to: [ "again@example.com" ])

    assert_enqueued_with(job: SendEmailJob) do
      original.resend
    end
  end

  test "resend reconstructs attachments from the archived eml" do
    original = submit_email(to: [ "files@example.com" ],
      attachments: [ { filename: "hello.txt", content_type: "text/plain",
        content: Base64.strict_encode64("hello world") } ])

    resent = original.resend

    assert_equal [ "hello.txt" ], resent.attachments.pluck(:filename)
    resent_part = Mail.new(Email::MimeStore.read(resent)).attachments.first
    assert_equal "hello.txt", resent_part.filename
    assert_equal "hello world", resent_part.body.decoded
  end

  test "resend refuses when recipients are now suppressed" do
    original = submit_email(to: [ "later-blocked@example.com" ])
    Suppression.record(@project, "later-blocked@example.com", reason: "complaint")

    assert_no_difference -> { Email.count } do
      assert_not original.resend
    end
  end

  test "resend refuses when attachments existed but the eml was pruned" do
    original = submit_email(to: [ "files@example.com" ],
      attachments: [ { filename: "hello.txt", content_type: "text/plain",
        content: Base64.strict_encode64("hello world") } ])
    Email::MimeStore.delete(original)
    original.update!(mime_path: nil)

    assert_not original.resend
  end

  test "retry_soft_bounces resends only transient bounces up to the limit and skips suppressed" do
    wipe_send_domain
    soft_one = submit_email(to: [ "soft1@example.com" ])
    soft_two = submit_email(to: [ "soft2@example.com" ])
    hard = submit_email(to: [ "hard@example.com" ])
    [ soft_one, soft_two ].each { |email| email.update_columns(status: "bounced", bounce_type: "transient") }
    hard.update_columns(status: "bounced", bounce_type: "permanent")
    Suppression.record(@project, "soft2@example.com", reason: "complaint")

    count = assert_difference -> { Email.count }, +1 do
      @project.emails.retry_soft_bounces(limit: 100)
    end
    assert_equal 1, count
    assert_equal "soft1@example.com", Email.order(:id).last.recipients.kind_to.first.address
  end

  private
    def submit_email(to:, attachments: [])
      EmailSubmission.new(project: @project, source: sources(:acme_production), from: "hello@acme.com",
        to: to, subject: "Resend me", text: "Body", attachments: attachments).save
    end
end

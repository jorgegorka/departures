require "test_helper"

class Email::DeliverableTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  STORED_EML = "raw mime bytes".freeze

  setup do
    Current.session = sessions(:owner)
    @email = create_email_with_mime
    @client = Aws::SESV2::Client.new(stub_responses: true)
    @client.stub_responses(:send_email, message_id: "ses-message-123")
    @email.source.ses_client = @client
  end

  teardown do
    Email::MimeStore.delete(@email)
  end

  test "deliver sends the stored MIME with an explicit destination and marks sent" do
    assert @email.deliver

    request = @client.api_requests.sole
    assert_equal :send_email, request[:operation_name]
    assert_equal STORED_EML, request[:params][:content][:raw][:data]
    assert_equal [ "user@example.com" ], request[:params][:destination][:to_addresses]
    assert_equal [ "copy@example.com" ], request[:params][:destination][:cc_addresses]
    assert_equal [ "hidden@example.com" ], request[:params][:destination][:bcc_addresses]

    @email.reload
    assert_equal "sent", @email.status
    assert_equal "ses-message-123", @email.ses_message_id
  end

  test "deliver from sending still sends — a retried attempt must not no-op" do
    @email.mark_sending

    @email.deliver

    assert_equal 1, @client.api_requests.size
    assert_equal "sent", @email.reload.status
  end

  test "deliver refuses emails already past sending" do
    @email.update!(status: "sent")
    assert_not @email.deliver

    @email.update!(status: "failed")
    assert_not @email.deliver

    assert_empty @client.api_requests
  end

  test "an SES error propagates for the job to retry, leaving the email sending" do
    @client.stub_responses(:send_email,
      Aws::SESV2::Errors::MessageRejected.new(nil, "Email address is not verified"))

    assert_raises Aws::SESV2::Errors::MessageRejected do
      @email.deliver
    end

    @email.reload
    assert_equal "sending", @email.status
    assert_nil @email.ses_message_id
  end

  test "deliver_later enqueues the job" do
    assert_enqueued_with(job: SendEmailJob, args: [ @email ], queue: "default") do
      @email.deliver_later
    end
  end

  private
    def create_email_with_mime
      email = Email.create!(project: projects(:acme_default), source: sources(:acme_production),
        from: "hello@acme.com", subject: "Hi", html_body: "<p>Hi</p>")
      email.recipients.create!(kind: "to", address: "user@example.com")
      email.recipients.create!(kind: "cc", address: "copy@example.com")
      email.recipients.create!(kind: "bcc", address: "hidden@example.com")
      Email::MimeStore.write(email, STORED_EML)
      email
    end
end

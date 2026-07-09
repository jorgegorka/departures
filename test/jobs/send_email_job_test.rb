require "test_helper"

class SendEmailJobTest < ActiveJob::TestCase
  setup do
    Current.session = sessions(:owner)
    @email = Email.create!(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", subject: "Hi", html_body: "<p>Hi</p>")
    @email.recipients.create!(kind: "to", address: "user@example.com")
    Email::MimeStore.write(@email, "raw mime bytes")
  end

  teardown do
    Email::MimeStore.delete(@email)
  end

  test "performs a delivery end to end" do
    stubbed = Aws::SESV2::Client.new(stub_responses: true)
    stubbed.stub_responses(:send_email, message_id: "ses-job-1")

    # GlobalID deserialization hands the job a FRESH Source instance, so a stub
    # injected on our in-memory source is lost — stub the constructor instead.
    Aws::SESV2::Client.stub :new, stubbed do
      perform_enqueued_jobs do
        SendEmailJob.perform_later(@email)
      end
    end

    @email.reload
    assert_equal "sent", @email.status
    assert_equal "ses-job-1", @email.ses_message_id
  end

  test "exhausted SES retries mark the email failed with the reason" do
    stubbed = Aws::SESV2::Client.new(stub_responses: true)
    stubbed.stub_responses(:send_email,
      Aws::SESV2::Errors::MessageRejected.new(nil, "Email address is not verified"))

    Aws::SESV2::Client.stub :new, stubbed do
      perform_enqueued_jobs do
        SendEmailJob.perform_later(@email)
      end
    end

    @email.reload
    assert_equal "failed", @email.status
    assert_equal "Email address is not verified", @email.failure_reason
    assert_equal 3, stubbed.api_requests.size, "all three attempts must reach SES (retry-guard regression)"
  end

  test "exhausted networking retries mark the email failed with the reason" do
    stubbed = Aws::SESV2::Client.new(stub_responses: true)
    stubbed.stub_responses(:send_email,
      Seahorse::Client::NetworkingError.new(Net::OpenTimeout.new("open timeout")))

    Aws::SESV2::Client.stub :new, stubbed do
      perform_enqueued_jobs do
        SendEmailJob.perform_later(@email)
      end
    end

    @email.reload
    assert_equal "failed", @email.status
    assert @email.failure_reason.present?, "a networking failure must record a reason"
    assert_equal 3, stubbed.api_requests.size, "all three attempts must reach SES (retry-guard regression)"
  end

  test "the job carries the workspace context from enqueue time" do
    stubbed = Aws::SESV2::Client.new(stub_responses: true)
    stubbed.stub_responses(:send_email, message_id: "ses-job-2")
    Current.workspace = workspaces(:acme)

    job = SendEmailJob.new(@email)
    assert_equal workspaces(:acme), job.workspace

    Current.reset
    Aws::SESV2::Client.stub :new, stubbed do
      job.perform_now
    end

    assert_equal "sent", @email.reload.status
  end
end

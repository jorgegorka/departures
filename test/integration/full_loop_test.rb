# test/integration/full_loop_test.rb
require "test_helper"
require "turbo/broadcastable/test_helper"

# End-to-end proof of the platform loop from the master plan's Verification
# section: onboard -> issue key -> API send through stubbed SES -> SNS bounce
# -> suppression + live broadcast -> resend to the suppressed address blocked.
class FullLoopTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include Turbo::Broadcastable::TestHelper

  class AuthenticVerifier
    def authentic?(_message)
      true
    end
  end

  SES_MESSAGE_ID = "ses-smoke-0001"
  RECIPIENT = "customer@example.com"

  test "an email round-trips from onboarding to a blocked resend" do
    wipe_workspace_records

    # Registration is open on an empty database and bootstraps workspace + session.
    post registration_url, params: { email_address: "founder@acme-smoke.com",
      password: "secret123456", password_confirmation: "secret123456" }
    assert_redirected_to root_url

    workspace = Workspace.sole
    # No project UI exists; the dashboard picks the workspace's first active project.
    project = workspace.projects.create!(name: "Smoke")

    # Onboarding step: add a source.
    post sources_url, params: { source: { name: "Production", environment: "production",
      region: "eu-west-1", retention_days: 30,
      aws_access_key_id: "AKIASMOKE", aws_secret_access_key: "smoke-secret" } }
    assert_redirected_to sources_url
    source = project.sources.sole

    # Onboarding step: issue an API key and capture the one-time plaintext.
    post api_keys_url, params: { api_key: { name: "Smoke key", scopes: [ "send", "read:activity" ] } }
    assert_response :success
    bearer = response.body[/dp_[A-Za-z0-9]{48}/]
    assert bearer, "the create view must reveal the plaintext key once"

    # Guardrail: sending from an unverified domain is refused.
    post "/api/emails", params: send_params, headers: auth(bearer), as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body["errors"].join(" "), "domain is not verified"

    # Onboarding step: add the domain. The canned SES stub cannot report
    # verified_for_sending_status, so verification flips at the model — the
    # SES provision/check flows are covered by the Phase 5 domain tests.
    post domains_url, params: { domain: { name: "acme-smoke.com" } }
    project.domains.sole.update!(status: "verified")

    # The send is now accepted and delivered through stubbed SES.
    post "/api/emails", params: send_params, headers: auth(bearer), as: :json
    assert_response :accepted
    email = project.emails.find_by!(public_id: response.parsed_body["id"])

    ses = Aws::SESV2::Client.new(stub_responses: true, region: "eu-west-1")
    ses.stub_responses(:send_email, message_id: SES_MESSAGE_ID)
    Aws::SESV2::Client.stub :new, ses do
      perform_enqueued_jobs only: SendEmailJob
    end

    assert email.reload.sent?
    assert_equal SES_MESSAGE_ID, email.ses_message_id

    # SES reports a permanent bounce via SNS; ingestion is enqueued.
    Sns::MessageVerifier.stub :new, AuthenticVerifier.new do
      post "/api/webhooks/ses/#{source.webhook_token}", params: bounce_notification.to_json,
        headers: { "Content-Type" => "text/plain" }
    end
    assert_response :ok

    # Processing advances the status, records the event, suppresses the
    # recipient, and refreshes the live activity stream.
    streams = capture_turbo_stream_broadcasts([ project, :activity ]) do
      perform_enqueued_jobs only: ProcessSesEventJob
    end
    assert_equal "refresh", streams.sole["action"]

    assert email.reload.bounced?
    assert_equal "permanent", email.bounce_type
    assert_equal [ "bounce" ], email.events.pluck(:event_type)
    assert_includes Suppression.covers?(project, [ RECIPIENT ]), RECIPIENT

    # Finish onboarding so the dashboard opens up, then the resend is blocked.
    post onboarding_completion_url
    assert workspace.reload.onboarded?

    assert_no_difference -> { Email.count } do
      post email_resend_url(email)
    end
    assert_redirected_to email_url(email)
    assert_match(/suppressed/, flash[:alert])
  end

  private
    def auth(bearer)
      { "Authorization" => "Bearer #{bearer}" }
    end

    def send_params
      { from: "hello@acme-smoke.com", to: [ RECIPIENT ],
        subject: "Smoke test", html: "<p>Hello</p>", text: "Hello" }
    end

    def bounce_notification
      message = JSON.parse(file_fixture("sns/bounce_permanent.json").read)
      message["mail"]["messageId"] = SES_MESSAGE_ID
      message["mail"]["destination"] = [ RECIPIENT ]
      message["bounce"]["bouncedRecipients"] = [ { "emailAddress" => RECIPIENT, "action" => "failed",
        "status" => "5.1.1", "diagnosticCode" => "smtp; 550 5.1.1 user unknown" } ]

      { "Type" => "Notification", "MessageId" => "sns-smoke-1",
        "TopicArn" => "arn:aws:sns:eu-west-1:123456789012:departures",
        "Message" => message.to_json, "Timestamp" => "2026-07-01T10:00:05.000Z",
        "SignatureVersion" => "1", "Signature" => "sig",
        "SigningCertURL" => "https://sns.eu-west-1.amazonaws.com/cert.pem" }
    end
end

require "test_helper"

class Webhooks::SesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  class FakeVerifier
    def initialize(authentic)
      @authentic = authentic
    end

    def authentic?(_message)
      @authentic
    end
  end

  setup do
    Rails.cache.clear
  end

  def notification_payload(**overrides)
    { "Type" => "Notification", "MessageId" => "sns-1", "TopicArn" => "arn:aws:sns:eu-west-1:1:t",
      "Message" => { "eventType" => "Delivery", "mail" => { "messageId" => "m-1" } }.to_json,
      "Timestamp" => "2026-07-01T10:00:00.000Z", "SignatureVersion" => "1",
      "Signature" => "sig", "SigningCertURL" => "https://sns.eu-west-1.amazonaws.com/c.pem" }.merge(overrides)
  end

  def post_webhook(token: sources(:acme_production).webhook_token, body: notification_payload.to_json, authentic: true)
    Sns::MessageVerifier.stub :new, FakeVerifier.new(authentic) do
      post "/api/webhooks/ses/#{token}", params: body, headers: { "Content-Type" => "text/plain" }
    end
  end

  test "an unknown webhook token is not found and creates no log" do
    assert_no_difference -> { WebhookLog.count } do
      post_webhook(token: "no-such-token")
    end

    assert_response :not_found
  end

  test "a verified notification logs the payload and enqueues processing" do
    log = nil
    assert_difference -> { WebhookLog.count }, +1 do
      assert_enqueued_with(job: ProcessSesEventJob) do
        post_webhook
      end
    end

    assert_response :ok
    log = WebhookLog.order(:id).last
    assert_equal sources(:acme_production), log.source
    assert_equal workspaces(:acme), log.workspace
    assert_equal "Notification", log.message_type
    assert_equal "received", log.status
    assert log.payload["Message"].present?
  end

  test "a bad signature keeps the log as failed and responds forbidden" do
    assert_difference -> { WebhookLog.count }, +1 do
      assert_no_enqueued_jobs only: ProcessSesEventJob do
        post_webhook(authentic: false)
      end
    end

    assert_response :forbidden
    log = WebhookLog.order(:id).last
    assert log.failed?
    assert_includes log.error, "signature"
  end

  test "a body that is not JSON is a bad request and creates no log" do
    assert_no_difference -> { WebhookLog.count } do
      post_webhook(body: "not json at all")
    end

    assert_response :bad_request
  end

  test "a valid-JSON non-object body is a bad request and creates no log" do
    [ "123", "[1]" ].each do |body|
      assert_no_difference -> { WebhookLog.count } do
        post_webhook(body: body)
      end

      assert_response :bad_request, body
    end
  end

  test "requests beyond 120 per minute per token are rejected" do
    Sns::MessageVerifier.stub :new, FakeVerifier.new(true) do
      120.times do
        post "/api/webhooks/ses/#{sources(:acme_production).webhook_token}",
          params: notification_payload.to_json, headers: { "Content-Type" => "text/plain" }
        assert_response :ok
      end

      post "/api/webhooks/ses/#{sources(:acme_production).webhook_token}",
        params: notification_payload.to_json, headers: { "Content-Type" => "text/plain" }
      assert_response :too_many_requests
    end
  end

  test "a transient certificate network error is logged failed and responds service unavailable" do
    raising_verifier = Object.new
    def raising_verifier.authentic?(_message)
      raise SocketError, "getaddrinfo: nodename nor servname provided"
    end

    assert_difference -> { WebhookLog.count }, +1 do
      assert_no_enqueued_jobs only: ProcessSesEventJob do
        Sns::MessageVerifier.stub :new, raising_verifier do
          post "/api/webhooks/ses/#{sources(:acme_production).webhook_token}",
            params: notification_payload.to_json, headers: { "Content-Type" => "text/plain" }
        end
      end
    end

    assert_response :service_unavailable
    log = WebhookLog.order(:id).last
    assert log.failed?
    assert_includes log.error, "getaddrinfo"
  end

  test "a cert-fetch failure raised before the log exists still returns 503" do
    source = sources(:acme_production)
    failing_logs = Object.new
    def failing_logs.create!(**) = raise IOError, "disk full"

    source.stub :webhook_logs, failing_logs do
      Source.stub :find_by, source do
        post ses_webhooks_path(webhook_token: source.webhook_token),
          params: { "Type" => "Notification", "Message" => "{}" }.to_json,
          headers: { "CONTENT_TYPE" => "text/plain" }
      end
    end

    assert_response :service_unavailable
  end
end

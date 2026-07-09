require "test_helper"

class Sns::MessageVerifierTest < ActiveSupport::TestCase
  KEY = OpenSSL::PKey::RSA.new(2048)
  CERT = OpenSSL::X509::Certificate.new.tap do |cert|
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=sns.test")
    cert.public_key = KEY.public_key
    cert.serial = 1
    cert.version = 2
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + 86_400
    cert.sign(KEY, OpenSSL::Digest.new("SHA256"))
  end
  CERT_URL = "https://sns.eu-west-1.amazonaws.com/SimpleNotificationService-test.pem".freeze

  test "verifies a SignatureVersion 1 notification" do
    assert verifier.authentic?(signed_notification)
  end

  test "verifies a SignatureVersion 2 notification with SHA256" do
    assert verifier.authentic?(signed_notification("SignatureVersion" => "2"))
  end

  test "verifies a subscription confirmation over its own key set" do
    message = signed_message("Type" => "SubscriptionConfirmation", "Token" => "tok-123",
      "SubscribeURL" => "https://sns.eu-west-1.amazonaws.com/?Action=ConfirmSubscription")

    assert verifier.authentic?(message)
  end

  test "a notification without a Subject still verifies" do
    assert verifier.authentic?(signed_notification("Subject" => nil))
  end

  test "rejects a tampered Message" do
    message = signed_notification
    message["Message"] = "{\"eventType\":\"Tampered\"}"

    assert_not verifier.authentic?(message)
  end

  test "rejects a signature produced by a different key" do
    message = signed_notification
    message["Signature"] = Base64.strict_encode64(
      OpenSSL::PKey::RSA.new(2048).sign(OpenSSL::Digest.new("SHA1"), "whatever"))

    assert_not verifier.authentic?(message)
  end

  test "rejects a cert URL on the wrong host without fetching it" do
    fetched = false
    suspicious = Sns::MessageVerifier.new(region: "eu-west-1",
      cert_fetcher: ->(_url) { fetched = true; CERT.to_pem })
    message = signed_notification("SigningCertURL" => "https://sns.eu-west-1.amazonaws.com.evil.example/cert.pem")

    assert_not suspicious.authentic?(message)
    assert_not fetched, "the pinning check must run before any fetch"
  end

  test "rejects a cert URL for another region, plain http, or a non-pem path" do
    [ "https://sns.us-east-1.amazonaws.com/cert.pem",
      "http://sns.eu-west-1.amazonaws.com/cert.pem",
      "https://sns.eu-west-1.amazonaws.com/cert.txt",
      "not a url" ].each do |url|
      assert_not verifier.authentic?(signed_notification("SigningCertURL" => url)), url
    end
  end

  test "rejects unknown signature versions and unknown message types" do
    assert_not verifier.authentic?(signed_notification("SignatureVersion" => "3"))
    assert_not verifier.authentic?(signed_notification("Type" => "Mystery"))
  end

  test "rejects when the fetched cert is garbage instead of raising" do
    broken = Sns::MessageVerifier.new(region: "eu-west-1", cert_fetcher: ->(_url) { "not a certificate" })

    assert_not broken.authentic?(signed_notification)
  end

  private
    def verifier
      Sns::MessageVerifier.new(region: "eu-west-1", cert_fetcher: ->(url) {
        raise "unexpected cert fetch: #{url}" unless url == CERT_URL
        CERT.to_pem
      })
    end

    def signed_notification(overrides = {})
      signed_message({ "Subject" => "Amazon SES Email Event Notification" }.merge(overrides))
    end

    # Independent implementation of the AWS canonical string, straight from the
    # SNS verification spec — deliberately NOT shared with production code.
    def signed_message(overrides = {})
      message = {
        "Type" => "Notification",
        "MessageId" => "sns-message-1",
        "TopicArn" => "arn:aws:sns:eu-west-1:123456789012:ses-events",
        "Message" => "{\"eventType\":\"Delivery\"}",
        "Timestamp" => "2026-07-01T10:00:00.000Z",
        "SignatureVersion" => "1",
        "SigningCertURL" => CERT_URL
      }.merge(overrides).compact
      message.merge("Signature" => signature_for(message))
    end

    def signature_for(message)
      keys = if message["Type"] == "Notification"
        %w[ Message MessageId Subject Timestamp TopicArn Type ]
      else
        %w[ Message MessageId SubscribeURL Timestamp Token TopicArn Type ]
      end
      digest = message["SignatureVersion"] == "2" ? "SHA256" : "SHA1"
      canonical = keys.filter_map { |key| "#{key}\n#{message[key]}\n" if message[key] }.join
      Base64.strict_encode64(KEY.sign(OpenSSL::Digest.new(digest), canonical))
    end
end

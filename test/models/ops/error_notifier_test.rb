require "test_helper"

class Ops::ErrorNotifierTest < ActiveSupport::TestCase
  SETTINGS = { aws_access_key_id: "AKIAOPS", aws_secret_access_key: "ops-secret",
               region: "eu-west-1", from: "alerts@departures.example", to: "jorge@example.com" }.freeze

  setup do
    @notifier = Ops::ErrorNotifier.new(settings: SETTINGS)
    @client = Aws::SESV2::Client.new(stub_responses: true)
    @notifier.ses_client = @client
    @error = ArgumentError.new("boom")
  end

  test "emails an unhandled error through SES" do
    @notifier.report(@error, handled: false, severity: :error, context: { job: "SendEmailJob" }, source: "application.active_job")

    assert_equal 1, @client.api_requests.size
    raw = @client.api_requests.first[:params][:content][:raw][:data]
    assert_includes raw, "ArgumentError"
    assert_includes raw, "boom"
    assert_includes raw, "To: jorge@example.com"
  end

  test "ignores handled errors" do
    @notifier.report(@error, handled: true, severity: :warning, context: {})

    assert_empty @client.api_requests
  end

  test "throttles repeats of the same error class within the window" do
    @notifier.report(@error, handled: false, severity: :error, context: {})
    @notifier.report(ArgumentError.new("boom again"), handled: false, severity: :error, context: {})

    assert_equal 1, @client.api_requests.size
  end

  test "a different error class alerts despite the throttle" do
    @notifier.report(@error, handled: false, severity: :error, context: {})
    @notifier.report(TypeError.new("other"), handled: false, severity: :error, context: {})

    assert_equal 2, @client.api_requests.size
  end

  test "no-ops without settings" do
    bare = Ops::ErrorNotifier.new(settings: nil)
    bare.ses_client = @client

    bare.report(@error, handled: false, severity: :error, context: {})

    assert_empty @client.api_requests
  end

  test "never raises when SES delivery fails" do
    @client.stub_responses(:send_email, "MessageRejected")

    assert_nothing_raised do
      @notifier.report(@error, handled: false, severity: :error, context: {})
    end
  end
end

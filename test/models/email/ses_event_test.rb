require "test_helper"

class Email::SesEventTest < ActiveSupport::TestCase
  test "normalizes event types from configuration-set eventType" do
    { "send" => "send", "delivery" => "delivery", "bounce_permanent" => "bounce",
      "complaint" => "complaint", "open" => "open", "click" => "click",
      "reject" => "reject", "delivery_delay" => "delivery_delay" }.each do |fixture, expected|
      assert_equal expected, event(fixture).event_type, fixture
    end
  end

  test "accepts classic notificationType payloads" do
    payload = fixture_payload("bounce_permanent").except("eventType").merge("notificationType" => "Bounce")

    assert_equal "bounce", Email::SesEvent.new(payload).event_type
  end

  test "exposes the ses message id from the mail object" do
    assert_equal "ses-fixture-message-1", event("delivery").ses_message_id
  end

  test "recipients come from the event detail when it names them" do
    assert_equal [ "user@example.com" ], event("delivery").recipients
    assert_equal [ "bounce@example.com" ], event("bounce_permanent").recipients
    assert_equal [ "complainer@example.com" ], event("complaint").recipients
  end

  test "recipients fall back to the mail destination for opens, clicks, sends, and rejects" do
    %w[ send open click reject ].each do |fixture|
      assert_equal [ "user@example.com" ], event(fixture).recipients, fixture
    end
  end

  test "occurred_at prefers the event detail timestamp over the mail timestamp" do
    assert_equal Time.iso8601("2026-07-01T10:00:02.000Z"), event("delivery").occurred_at
    assert_equal Time.iso8601("2026-07-01T09:59:58.000Z"), event("send").occurred_at
  end

  test "occurred_at falls back to now when no timestamp survives" do
    event = Email::SesEvent.new({ "eventType" => "Send" })

    assert_in_delta Time.current, event.occurred_at, 2.seconds
  end

  test "suppresses on complaints and permanent bounces only" do
    assert event("complaint").suppresses?
    assert event("bounce_permanent").suppresses?
    assert_not event("bounce_transient").suppresses?
    assert_not event("delivery").suppresses?
  end

  test "an undetermined bounce is not permanent and never suppresses" do
    payload = fixture_payload("bounce_permanent")
    payload["bounce"]["bounceType"] = "Undetermined"
    event = Email::SesEvent.new(payload)

    assert event.bounce?
    assert_not event.permanent_bounce?
    assert_not event.suppresses?
  end

  test "open and click expose their metadata" do
    open_event = event("open")
    assert_equal "192.0.2.1", open_event.ip
    assert_equal "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5)", open_event.user_agent
    assert_nil open_event.url

    click_event = event("click")
    assert_equal "https://acme.com/welcome", click_event.url
    assert_equal "192.0.2.1", click_event.ip
  end

  test "recipients drops nil and blank addresses" do
    event = Email::SesEvent.new(
      "eventType" => "Bounce",
      "bounce" => { "bouncedRecipients" => [ { "emailAddress" => "real@example.com" }, {}, { "emailAddress" => "" } ] })

    assert_equal [ "real@example.com" ], event.recipients
  end

  private
    def fixture_payload(name)
      JSON.parse(file_fixture("sns/#{name}.json").read)
    end

    def event(name)
      Email::SesEvent.new(fixture_payload(name))
    end
end

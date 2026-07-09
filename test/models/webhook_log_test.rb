require "test_helper"

class WebhookLogTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Current.session = sessions(:owner)
  end

  test "workspace defaults from the source" do
    log = sources(:acme_production).webhook_logs.create!(message_type: "Notification", payload: { "Type" => "Notification" })

    assert_equal workspaces(:acme), log.workspace
    assert_equal "received", log.status
  end

  test "status is constrained to the known set" do
    log = sources(:acme_production).webhook_logs.build(payload: {}, status: "bogus")

    assert_not log.valid?
    assert log.errors[:status].any?
  end

  # --- Ingestion (roadmap 3.5) ---

  FIXTURE_MESSAGE_ID = "ses-fixture-message-1".freeze

  test "a delivery notification records an event and advances the email" do
    email = matched_email
    log = process_fixture("delivery")

    event = email.events.sole
    assert_equal "delivery", event.event_type
    assert_equal "user@example.com", event.recipient
    assert_equal Time.iso8601("2026-07-01T10:00:02.000Z"), event.occurred_at
    assert_equal FIXTURE_MESSAGE_ID, event.ses_message_id
    assert_equal "delivered", email.reload.status
    assert log.processed?
    assert log.processed_at.present?
  end

  test "open and click events carry their metadata" do
    email = matched_email
    process_fixture("open")
    process_fixture("click")

    open_event, click_event = email.events.order(:id).last(2)
    assert_equal "192.0.2.1", open_event.ip
    assert open_event.user_agent.present?
    assert_equal "https://acme.com/welcome", click_event.url
    assert_equal "clicked", email.reload.status
  end

  test "a permanent bounce suppresses the recipient" do
    email = matched_email

    assert_difference -> { Suppression.count }, +1 do
      process_fixture("bounce_permanent")
    end

    suppression = Suppression.order(:id).last
    assert_equal "bounce@example.com", suppression.email
    assert_equal "bounce", suppression.reason
    assert_nil suppression.expires_at
    assert_equal projects(:acme_default), suppression.project
    assert_equal "bounced", email.reload.status
  end

  test "a transient bounce never suppresses but still bounces the email" do
    email = matched_email

    assert_no_difference -> { Suppression.count } do
      process_fixture("bounce_transient")
    end

    assert_equal "bounced", email.reload.status
    assert_equal "bounce", email.events.sole.event_type
  end

  test "an undetermined bounce never suppresses" do
    matched_email

    assert_no_difference -> { Suppression.count } do
      process_fixture("bounce_permanent", overrides: { "bounce" => { "bounceType" => "Undetermined" } })
    end
  end

  test "a complaint suppresses with the complaint reason" do
    email = matched_email
    process_fixture("complaint")

    suppression = Suppression.order(:id).last
    assert_equal "complainer@example.com", suppression.email
    assert_equal "complaint", suppression.reason
    assert_equal "complained", email.reload.status
  end

  test "a bounce for an address with an expired suppression reactivates it" do
    matched_email
    lapsed = suppressions(:acme_lapsed)

    assert_no_difference -> { Suppression.count } do
      process_fixture("bounce_permanent",
        overrides: { "bounce" => { "bouncedRecipients" => [ { "emailAddress" => lapsed.email } ] } })
    end

    lapsed.reload
    assert_nil lapsed.expires_at
    assert_equal "bounce", lapsed.reason
  end

  test "out-of-order events never regress status but are still recorded (risk #4)" do
    email = matched_email
    process_fixture("click")
    process_fixture("delivery")

    assert_equal "clicked", email.reload.status
    assert_equal %w[ click delivery ], email.events.order(:id).pluck(:event_type)
  end

  test "a delivery delay records an event without touching status" do
    email = matched_email
    email.mark_sent

    log = process_fixture("delivery_delay")

    assert_equal "sent", email.reload.status
    assert_equal "delivery_delay", email.events.sole.event_type
    assert log.processed?
  end

  test "an event with no matching email marks the log unmatched and keeps the payload" do
    log = process_fixture("delivery")

    assert log.unmatched?
    assert_equal 0, EmailEvent.count
    assert log.payload["Message"].present?
  end

  test "an email on another source with the same ses message id is never matched" do
    Email.create!(project: projects(:globex_default), source: sources(:globex_production),
      from: "hello@globex.com", subject: "Other tenant", html_body: "<p>x</p>",
      status: "sent", ses_message_id: FIXTURE_MESSAGE_ID)

    log = process_fixture("delivery")

    assert log.unmatched?
    assert_equal 0, EmailEvent.count
  end

  test "malformed inner Message JSON fails the log with the parse error" do
    log = sources(:acme_production).webhook_logs.create!(message_type: "Notification",
      payload: { "Type" => "Notification", "Message" => "{not json" })

    log.process

    assert log.failed?
    assert log.error.present?
  end

  test "a subscription confirmation GETs a pinned SubscribeURL and marks the log processed" do
    subscribe_url = "https://sns.eu-west-1.amazonaws.com/?Action=ConfirmSubscription&Token=tok"
    log = sources(:acme_production).webhook_logs.create!(message_type: "SubscriptionConfirmation",
      payload: { "Type" => "SubscriptionConfirmation", "SubscribeURL" => subscribe_url })

    fetched_urls = []
    Net::HTTP.stub :get_response, ->(uri) { fetched_urls << uri.to_s; Net::HTTPOK.new("1.1", "200", "OK") } do
      log.process
    end

    assert_equal [ subscribe_url ], fetched_urls
    assert log.processed?
  end

  test "a subscription confirmation with a foreign SubscribeURL is never fetched" do
    log = sources(:acme_production).webhook_logs.create!(message_type: "SubscriptionConfirmation",
      payload: { "Type" => "SubscriptionConfirmation", "SubscribeURL" => "https://evil.example/confirm" })

    Net::HTTP.stub :get_response, ->(_uri) { flunk "must not fetch a foreign host" } do
      log.process
    end

    assert log.failed?
    assert_includes log.error, "SubscribeURL"
  end

  test "process_later enqueues the job" do
    log = sources(:acme_production).webhook_logs.create!(message_type: "Notification",
      payload: { "Type" => "Notification" })

    assert_enqueued_with(job: ProcessSesEventJob, args: [ log ], queue: "default") do
      log.process_later
    end
  end

  private
    def matched_email
      Email.create!(project: projects(:acme_default), source: sources(:acme_production),
        from: "hello@acme.com", subject: "Tracked", html_body: "<p>hi</p>",
        status: "sent", ses_message_id: FIXTURE_MESSAGE_ID)
    end

    def process_fixture(name, overrides: {})
      message = JSON.parse(file_fixture("sns/#{name}.json").read).deep_merge(overrides)
      log = sources(:acme_production).webhook_logs.create!(message_type: "Notification",
        payload: { "Type" => "Notification", "MessageId" => "sns-#{name}", "Message" => message.to_json })
      log.process
      log
    end
end

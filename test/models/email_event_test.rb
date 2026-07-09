require "test_helper"

class EmailEventTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    @email = Email.create!(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", subject: "Hi", html_body: "<p>Hi</p>")
  end

  test "requires an event type and an occurrence time" do
    event = @email.events.build

    assert_not event.valid?
    assert event.errors[:event_type].any?
    assert event.errors[:occurred_at].any?
  end

  test "reverse_chronologically orders newest occurrence first" do
    older = @email.events.create!(event_type: "send", occurred_at: 2.hours.ago)
    newer = @email.events.create!(event_type: "delivery", occurred_at: 1.hour.ago)

    assert_equal [ newer, older ], @email.events.reverse_chronologically.to_a
  end

  test "destroying the email destroys its events" do
    @email.events.create!(event_type: "send", occurred_at: Time.current)

    assert_difference -> { EmailEvent.count }, -1 do
      @email.destroy
    end
  end
end

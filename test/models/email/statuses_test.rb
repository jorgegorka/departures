require "test_helper"

class Email::StatusesTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    @email = emails(:acme_welcome)
  end

  # event applied to current status => expected resulting status
  PRECEDENCE_TABLE = [
    [ "queued",     "delivery",  "delivered"  ],
    [ "sent",       "delivery",  "delivered"  ],
    [ "delivered",  "open",      "opened"     ],
    [ "opened",     "click",     "clicked"    ],
    [ "clicked",    "delivery",  "clicked"    ], # never regresses
    [ "clicked",    "open",      "clicked"    ], # never regresses
    [ "delivered",  "bounce",    "bounced"    ],
    [ "bounced",    "complaint", "complained" ],
    [ "complained", "bounce",    "complained" ], # complaint outranks bounce
    [ "sent",       "send",      "sent"       ], # same status is not a forward move
    [ "queued",     "reject",    "failed"     ]
  ].freeze

  test "apply_event only ever advances status" do
    PRECEDENCE_TABLE.each do |current, event, expected|
      @email.update_columns(status: current)

      @email.apply_event(event)

      assert_equal expected, @email.reload.status, "#{current} + #{event} should be #{expected}"
    end
  end

  test "apply_event returns false and is a no-op for unknown event types" do
    assert_not @email.apply_event("subscription")
    assert_equal "queued", @email.reload.status
  end

  test "mark_sending, mark_sent advance forward only" do
    assert @email.mark_sending
    assert_equal "sending", @email.status

    assert @email.mark_sent
    assert_equal "sent", @email.status

    assert_not @email.mark_sending
    assert_equal "sent", @email.reload.status
  end

  test "mark_failed records the reason" do
    assert @email.mark_failed("MessageRejected: address not verified")

    assert_equal "failed", @email.status
    assert_equal "MessageRejected: address not verified", @email.failure_reason
  end

  test "precedence map covers every enum status" do
    assert_equal Email.statuses.keys.sort, Email::Statuses::STATUS_PRECEDENCE.keys.sort
  end
end

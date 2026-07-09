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

  # --- Phase 3 prerequisite: row-guarded advance (risk #4) ---

  test "a stale in-memory copy cannot regress a concurrently advanced status" do
    email = fresh_email
    concurrent_copy = Email.find(email.id)
    concurrent_copy.apply_event("delivery")

    assert_not email.mark_sent, "the guarded write must match zero rows"
    assert_equal "delivered", email.status, "advance_to must reload so memory matches the row"
  end

  test "mark_sent persists the ses message id in the same guarded write" do
    email = fresh_email

    assert email.mark_sent(ses_message_id: "ses-fold-1")
    assert_equal "ses-fold-1", email.reload.ses_message_id
  end

  test "a rejected advance writes none of the extra attributes" do
    email = fresh_email
    email.apply_event("delivery")

    assert_not email.mark_sent(ses_message_id: "too-late")
    assert_nil email.reload.ses_message_id
  end

  test "a successful advance keeps the in-memory updated_at in sync with the row" do
    email = emails(:acme_welcome)

    email.mark_sending
    in_memory = email.updated_at

    assert_equal email.reload.updated_at.to_f, in_memory.to_f
  end

  private
    def fresh_email
      Email.create!(project: projects(:acme_default), source: sources(:acme_production),
        from: "hello@acme.com", subject: "Race", html_body: "<p>race</p>")
    end
end

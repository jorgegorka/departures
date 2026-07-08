module Email::Statuses
  extend ActiveSupport::Concern

  STATUS_PRECEDENCE = {
    "queued" => 0, "sending" => 10, "sent" => 20, "delivered" => 30,
    "opened" => 40, "clicked" => 50, "bounced" => 60, "complained" => 70, "failed" => 80
  }.freeze

  EVENT_STATUSES = {
    "send" => "sent", "delivery" => "delivered", "open" => "opened", "click" => "clicked",
    "bounce" => "bounced", "complaint" => "complained", "reject" => "failed"
  }.freeze

  included do
    enum :status, STATUS_PRECEDENCE.keys.index_by(&:itself), default: "queued", validate: true
  end

  def apply_event(event_type)
    status_for_event = EVENT_STATUSES[event_type.to_s]

    if status_for_event
      advance_to(status_for_event)
    else
      false
    end
  end

  def mark_sending
    advance_to("sending")
  end

  def mark_sent
    advance_to("sent")
  end

  def mark_failed(reason)
    advance_to("failed", failure_reason: reason)
  end

  private
    def advance_to(new_status, **attributes)
      if STATUS_PRECEDENCE.fetch(new_status) > STATUS_PRECEDENCE.fetch(status)
        update!(status: new_status, **attributes)
        true
      else
        false
      end
    end
end

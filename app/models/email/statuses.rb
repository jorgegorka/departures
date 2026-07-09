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

  def mark_sent(**attributes)
    advance_to("sent", **attributes)
  end

  def mark_failed(reason)
    advance_to("failed", failure_reason: reason)
  end

  private
    # Compare-and-set in the WHERE clause: SQLite has no SELECT ... FOR UPDATE,
    # so the precedence check must live inside the single UPDATE statement.
    # update_all skips validations/callbacks — fine here, new_status only ever
    # comes from the internal maps above. On success we know exactly what the row
    # now holds, so we mirror it in memory; on a rejected write a concurrent
    # writer owns the row, so we reload to learn its real state. Never reloading
    # on success keeps the association cache (and any memoized client) intact.
    def advance_to(new_status, **attributes)
      advanced = self.class.where(id: id, status: lower_precedence_statuses(new_status))
        .update_all(status: new_status, updated_at: Time.current, **attributes) == 1

      if advanced
        assign_attributes(status: new_status, **attributes)
        changes_applied # update_all already persisted these — keep the record clean
        broadcast_activity
      else
        reload
      end

      advanced
    end

    def lower_precedence_statuses(new_status)
      new_rank = STATUS_PRECEDENCE.fetch(new_status)
      STATUS_PRECEDENCE.filter_map { |name, rank| name if rank < new_rank }
    end
end

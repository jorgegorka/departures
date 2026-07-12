module Email::Deliverable
  extend ActiveSupport::Concern

  # Delivery is at-least-once: if the worker crashes between SES accepting the send
  # and mark_sent committing, a retry sees `sending` and re-sends. Duplicate
  # ses_message_ids in that narrow window are expected, not a bug.
  def deliver
    return false unless deliverable? # guard at the start of a non-trivial body — §5.1 OK

    # Resolve the client before mark_sending: advance_to reloads on a rejected
    # write (e.g. a concurrent retry already advanced the row), which resets the
    # source association cache (and its memoized ses_client) — grab it first.
    client = source.ses_client
    mark_sending
    response = client.send_email(destination: destination,
      content: { raw: { data: Email::MimeStore.read(self) } })
    mark_sent(ses_message_id: response.message_id)
  end

  def deliver_later
    SendEmailJob.perform_later(self)
  end

  private
    def deliverable?
      queued? || sending?
    end

    def destination
      addresses_by_kind.transform_keys { |kind| :"#{kind}_addresses" }
    end
end

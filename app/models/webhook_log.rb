class WebhookLog < ApplicationRecord
  SUBSCRIBE_HOST_PATTERN = /\Asns\.[a-z0-9-]+\.amazonaws\.com\z/

  belongs_to :source
  belongs_to :workspace, default: -> { source.workspace }

  enum :status, %w[ received processed unmatched failed ].index_by(&:itself),
    default: "received", validate: true

  PRUNE_AFTER = 30.days

  def self.prune
    where(created_at: ...PRUNE_AFTER.ago).in_batches.delete_all
  end

  # Solid Queue delivers at least once, so a retried or redelivered job may
  # call this again — only a received log processes; anything else is a no-op.
  def process
    return false unless received?

    case message_type
    when "SubscriptionConfirmation"
      confirm_subscription
    when "Notification"
      ingest_notification
    else
      update!(status: "processed", processed_at: Time.current)
    end
  end

  def process_later
    ProcessSesEventJob.perform_later(self)
  end

  private
    def confirm_subscription
      if confirmable_subscribe_url?
        Net::HTTP.get_response(URI.parse(payload["SubscribeURL"]))
        update!(status: "processed", processed_at: Time.current)
      else
        update!(status: "failed", error: "SubscribeURL is not a pinned SNS https endpoint")
      end
    end

    def confirmable_subscribe_url?
      uri = URI.parse(payload["SubscribeURL"].to_s)
      uri.is_a?(URI::HTTPS) && uri.host.to_s.match?(SUBSCRIBE_HOST_PATTERN)
    rescue URI::InvalidURIError
      false
    end

    def ingest_notification
      event = Email::SesEvent.new(JSON.parse(payload["Message"].to_s))
      email = source.emails.find_by(ses_message_id: event.ses_message_id)

      if email
        # One transaction so a mid-flight crash rolls back the event rows and
        # leaves the log received — a retry then reprocesses from scratch
        # instead of duplicating events.
        transaction do
          record_events(email, event)
          email.apply_event(event.event_type, **bounce_attributes(event))
          suppress_recipients(email, event)
          relay_to_endpoints(email, event)
          update!(status: "processed", processed_at: Time.current)
        end
      else
        update!(status: "unmatched", processed_at: Time.current)
      end
    rescue JSON::ParserError => error
      update!(status: "failed", error: error.message)
    end

    def record_events(email, event)
      addresses = event.recipients.presence || [ nil ]
      addresses.each do |address|
        email.events.create!(event_type: event.event_type, ses_message_id: event.ses_message_id,
          recipient: address, url: event.url, user_agent: event.user_agent, ip: event.ip,
          payload: event.payload, occurred_at: event.occurred_at)
      end
    end

    def bounce_attributes(event)
      if event.bounce?
        { bounce_type: event.bounce_type }
      else
        {}
      end
    end

    def suppress_recipients(email, event)
      if event.suppresses?
        event.recipients.each do |address|
          Suppression.record(email.project, address, reason: event.event_type)
        end
      end
    end

    # Runs inside the ingestion transaction, so this only ENQUEUES — the
    # HTTP happens in DeliverWebhookJob after commit (enqueue_after_transaction_commit).
    def relay_to_endpoints(email, event)
      email.project.webhook_endpoints.active.each do |endpoint|
        if endpoint.subscribed_to?(event.event_type)
          endpoint.deliveries.create!(email: email, event_type: event.event_type,
            payload: delivery_payload(email, event)).deliver_later
        end
      end
    end

    def delivery_payload(email, event)
      { "event" => event.event_type, "email_id" => email.public_id,
        "recipients" => event.recipients, "occurred_at" => event.occurred_at,
        "payload" => event.payload }
    end
end

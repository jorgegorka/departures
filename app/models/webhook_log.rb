class WebhookLog < ApplicationRecord
  SUBSCRIBE_HOST_PATTERN = /\Asns\.[a-z0-9-]+\.amazonaws\.com\z/

  belongs_to :source
  belongs_to :workspace, default: -> { source.workspace }

  enum :status, %w[ received processed unmatched failed ].index_by(&:itself),
    default: "received", validate: true

  def process
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
        record_events(email, event)
        email.apply_event(event.event_type)
        suppress_recipients(email, event)
        relay_to_endpoints(email, event)
        update!(status: "processed", processed_at: Time.current)
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

    def suppress_recipients(email, event)
      if event.suppresses?
        event.recipients.each do |address|
          Suppression.record(email.project, address, reason: event.event_type)
        end
      end
    end

    def relay_to_endpoints(email, event)
      # Outbound webhook fan-out fills this seam in Phase 5 (WebhookEndpoint).
    end
end

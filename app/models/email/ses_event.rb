class Email::SesEvent
  TIMESTAMP_SOURCES = {
    "bounce" => "bounce", "complaint" => "complaint", "delivery" => "delivery",
    "open" => "open", "click" => "click", "delivery_delay" => "deliveryDelay"
  }.freeze

  attr_reader :payload

  def initialize(payload)
    @payload = payload
  end

  def event_type
    raw_event_type.to_s.delete(" ").underscore
  end

  def ses_message_id
    payload.dig("mail", "messageId")
  end

  def recipients
    addresses =
      case event_type
      when "bounce"
        Array(payload.dig("bounce", "bouncedRecipients")).map { |recipient| recipient["emailAddress"] }
      when "complaint"
        Array(payload.dig("complaint", "complainedRecipients")).map { |recipient| recipient["emailAddress"] }
      when "delivery"
        Array(payload.dig("delivery", "recipients"))
      else
        Array(payload.dig("mail", "destination"))
      end

    addresses.filter_map { |address| address.presence }
  end

  def occurred_at
    Time.iso8601(raw_timestamp)
  rescue ArgumentError, TypeError
    Time.current
  end

  def bounce?
    event_type == "bounce"
  end

  def complaint?
    event_type == "complaint"
  end

  def permanent_bounce?
    bounce? && payload.dig("bounce", "bounceType") == "Permanent"
  end

  def suppresses?
    complaint? || permanent_bounce?
  end

  def url
    payload.dig("click", "link")
  end

  def user_agent
    payload.dig("open", "userAgent") || payload.dig("click", "userAgent")
  end

  def ip
    payload.dig("open", "ipAddress") || payload.dig("click", "ipAddress")
  end

  private
    def raw_event_type
      payload["eventType"] || payload["notificationType"]
    end

    def raw_timestamp
      detail_key = TIMESTAMP_SOURCES[event_type]
      detail_timestamp = detail_key && payload.dig(detail_key, "timestamp")
      detail_timestamp || payload.dig("mail", "timestamp")
    end
end

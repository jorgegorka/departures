class WebhookDelivery < ApplicationRecord
  class DeliveryError < StandardError; end
  class BlockedAddressError < StandardError; end

  MAX_RESPONSE_BODY = 1_000
  TIMEOUT = 5.seconds
  BLOCKED_RANGES = [
    IPAddr.new("0.0.0.0/8").freeze,
    IPAddr.new("100.64.0.0/10").freeze,
    IPAddr.new("224.0.0.0/4").freeze,
    IPAddr.new("240.0.0.0/4").freeze,
    IPAddr.new("198.18.0.0/15").freeze,
    IPAddr.new("::/128").freeze,
    IPAddr.new("ff00::/8").freeze,
    IPAddr.new("64:ff9b::/96").freeze
  ].freeze

  belongs_to :webhook_endpoint
  belongs_to :workspace, default: -> { webhook_endpoint.workspace }
  belongs_to :email, optional: true

  enum :status, %w[ pending succeeded failed ].index_by(&:itself), default: "pending", validate: true

  scope :reverse_chronologically, -> { order(created_at: :desc, id: :desc) }

  validates :event_type, presence: true

  # Solid Queue delivers at least once — a settled delivery must never post again.
  def deliver
    if pending?
      attempt
    else
      false
    end
  end

  def deliver_later
    DeliverWebhookJob.perform_later(self)
  end

  def mark_failed
    update!(status: "failed")
  end

  def signature(timestamp, body)
    OpenSSL::HMAC.hexdigest("SHA256", webhook_endpoint.secret, "#{timestamp}.#{body}")
  end

  private
    def attempt
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      begin
        response = post_payload
      rescue BlockedAddressError, SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, EOFError => error
        record_attempt(http_status: nil, body: error.message, started_at: started_at)
        raise DeliveryError, error.message
      end

      record_attempt(http_status: response.code.to_i, body: response.body, started_at: started_at)

      if response.is_a?(Net::HTTPSuccess)
        update!(status: "succeeded")
        true
      else
        raise DeliveryError, "endpoint responded with HTTP #{response.code}"
      end
    end

    def post_payload
      body = payload.to_json
      timestamp = Time.current.to_i
      uri = URI.parse(webhook_endpoint.url)

      http = Net::HTTP.new(uri.host, uri.port)
      http.ipaddr = validated_address(uri.hostname)
      http.use_ssl = uri.is_a?(URI::HTTPS)
      http.open_timeout = TIMEOUT.to_i
      http.read_timeout = TIMEOUT.to_i

      request = Net::HTTP::Post.new(uri.request_uri,
        "Content-Type" => "application/json",
        "User-Agent" => "Departures-Webhooks",
        "Departures-Signature" => "t=#{timestamp},v1=#{signature(timestamp, body)}")
      request.body = body

      http.request(request)
    end

    # Resolves once, rejects internal targets, and returns a pinned address so the
    # connection cannot be rebound to a different host between check and connect.
    def validated_address(hostname)
      addresses = Addrinfo.getaddrinfo(hostname, nil, nil, :STREAM).map { |info| IPAddr.new(info.ip_address) }

      if addresses.empty? || addresses.any? { |address| blocked_address?(address) }
        raise BlockedAddressError, "endpoint host resolves to a blocked address"
      end

      addresses.first.to_s
    end

    def blocked_address?(address)
      if address.loopback? || address.private? || address.link_local?
        true
      else
        BLOCKED_RANGES.any? { |range| range.include?(address) }
      end
    end

    def record_attempt(http_status:, body:, started_at:)
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1_000).round

      update!(attempts: attempts + 1, http_status: http_status,
        response_body: body.to_s.truncate(MAX_RESPONSE_BODY),
        latency_ms: elapsed_ms, last_attempted_at: Time.current)
    end
end

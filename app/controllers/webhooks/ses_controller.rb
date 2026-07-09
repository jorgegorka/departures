class Webhooks::SesController < ActionController::API
  # Transient failures fetching the SNS signing certificate (DNS, TCP, TLS)
  # escape the verifier as networking errors — treat them as retryable (503)
  # rather than letting a blip surface as a 500 to SNS.
  CERT_FETCH_ERRORS = [ SocketError, Timeout::Error, SystemCallError, IOError, OpenSSL::SSL::SSLError ].freeze

  # Declared first so floods are rejected before any database work.
  rate_limit to: 120, within: 1.minute, by: -> { params[:webhook_token] }, scope: :sns_webhook,
    with: -> { head :too_many_requests }

  before_action :set_source
  before_action :set_payload

  def create
    webhook_log = @source.webhook_logs.create!(message_type: @payload["Type"], payload: @payload)

    if verifier.authentic?(@payload)
      webhook_log.process_later
      head :ok
    else
      webhook_log.update!(status: "failed", error: "invalid SNS signature")
      head :forbidden
    end
  rescue *CERT_FETCH_ERRORS => error
    webhook_log&.update!(status: "failed", error: error.message)
    head :service_unavailable
  end

  private
    def set_source
      @source = Source.find_by(webhook_token: params[:webhook_token])

      if @source
        Current.workspace = @source.workspace
      else
        head :not_found
      end
    end

    # SNS posts JSON with Content-Type text/plain, so Rails never fills params.
    def set_payload
      @payload = JSON.parse(request.body.read)
      head :bad_request unless @payload.is_a?(Hash)
    rescue JSON::ParserError
      head :bad_request
    end

    def verifier
      Sns::MessageVerifier.new(region: @source.region)
    end
end

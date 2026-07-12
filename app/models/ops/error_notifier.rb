# Emails unhandled exceptions to the operator through dedicated ops SES
# credentials (deliberately not a tenant Source). Subscribed to Rails.error in
# production; silent when the ops credentials are absent. Accepted trade-off:
# a total SES outage also silences alerts — uptime monitoring covers that hole.
class Ops::ErrorNotifier
  THROTTLE_WINDOW = 10.minutes

  attr_writer :ses_client

  def initialize(settings: Rails.application.credentials.ops)
    @settings = settings
  end

  def report(error, handled:, severity:, context: {}, source: nil)
    return if handled || settings.blank? || throttled?(error)

    ses_client.send_email(content: { raw: { data: build_message(error, context, source).to_s } })
  rescue => notifier_error
    Rails.logger.error("Ops::ErrorNotifier failed: #{notifier_error.class}: #{notifier_error.message}")
  end

  private
    attr_reader :settings

    def throttled?(error)
      !Rails.cache.write("ops_error_notifier/#{error.class.name}", true,
        unless_exist: true, expires_in: THROTTLE_WINDOW)
    end

    def build_message(error, context, source)
      Mail.new.tap do |message|
        message.from = settings[:from]
        message.to = settings[:to]
        message.subject = "[Departures] #{error.class}: #{error.message.to_s.tr("\r\n", " ").truncate(120)}"
        message.body = <<~BODY
          #{error.class}: #{error.message}

          Source:  #{source || "unknown"}
          Context: #{context.inspect}

          #{Array(error.backtrace).first(20).join("\n")}
        BODY
      end
    end

    def ses_client
      @ses_client ||= Aws::SESV2::Client.new(region: settings[:region],
        credentials: Aws::Credentials.new(settings[:aws_access_key_id], settings[:aws_secret_access_key]),
        stub_responses: Rails.env.test?)
    end
end

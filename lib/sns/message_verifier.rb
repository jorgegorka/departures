require "net/http"

module Sns
  # Hand-ported SNS signature verification (risk #1): the aws-sdk gems in our
  # dependency set don't ship Aws::SNS::MessageVerifier. Pinned to the exact
  # per-region SNS cert host; SignatureVersion 1 → SHA1, 2 → SHA256.
  class MessageVerifier
    NOTIFICATION_KEYS = %w[ Message MessageId Subject Timestamp TopicArn Type ].freeze
    SUBSCRIPTION_KEYS = %w[ Message MessageId SubscribeURL Timestamp Token TopicArn Type ].freeze
    DIGESTS = { "1" => "SHA1", "2" => "SHA256" }.freeze

    def initialize(region:, cert_fetcher: nil)
      @region = region
      @cert_fetcher = cert_fetcher || method(:fetch_certificate)
    end

    def authentic?(message)
      digest_name = DIGESTS[message["SignatureVersion"].to_s]
      keys = signed_keys(message["Type"])

      if digest_name.nil? || keys.nil? || !pinned_certificate_url?(message["SigningCertURL"])
        false
      else
        verify(message, keys, digest_name)
      end
    rescue OpenSSL::OpenSSLError
      false
    end

    private
      attr_reader :region, :cert_fetcher

      def signed_keys(type)
        case type
        when "Notification" then NOTIFICATION_KEYS
        when "SubscriptionConfirmation", "UnsubscribeConfirmation" then SUBSCRIPTION_KEYS
        end
      end

      def pinned_certificate_url?(url)
        uri = URI.parse(url.to_s)
        uri.is_a?(URI::HTTPS) && uri.host == "sns.#{region}.amazonaws.com" && uri.path.end_with?(".pem")
      rescue URI::InvalidURIError
        false
      end

      def verify(message, keys, digest_name)
        certificate = OpenSSL::X509::Certificate.new(cert_fetcher.call(message["SigningCertURL"]))
        signature = Base64.decode64(message["Signature"].to_s)
        certificate.public_key.verify(OpenSSL::Digest.new(digest_name), signature, canonical_string(message, keys))
      end

      def canonical_string(message, keys)
        keys.filter_map { |key| "#{key}\n#{message[key]}\n" if message[key] }.join
      end

      def fetch_certificate(url)
        Rails.cache.fetch([ "sns-signing-cert", url ], expires_in: 1.day) do
          Net::HTTP.get(URI.parse(url))
        end
      end
  end
end

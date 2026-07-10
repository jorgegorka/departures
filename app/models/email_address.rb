# Plain-Ruby helper for reading RFC-5322 addresses. The platform accepts both
# bare addr-specs ("ann@example.com") and display-name forms
# ("Ann Smith <ann@example.com>") on the API and preserves the formatted string
# through to the MIME message, so every internal consumer that needs a bare
# address routes through here to extract the addr-spec.
class EmailAddress
  # RFC 5321 caps an addr-spec at 320 octets (64 local + 1 "@" + 255 domain).
  MAX_ADDRESS_LENGTH = 320

  class << self
    # The bare addr-spec, or nil unless the value parses as EXACTLY one
    # address. Mail::AddressList is used (not Mail::Address) because the
    # latter silently returns only the first address of a comma-separated
    # list — which would let one recipient string smuggle extra deliverable
    # addresses past validation, suppression, and recipient-count limits.
    def address_part(value)
      string = value.to_s
      return nil if string.blank?

      addresses = Mail::AddressList.new(string).addresses
      if addresses.one?
        addresses.first.address.presence
      else
        nil
      end
    rescue Mail::Field::IncompleteParseError, ArgumentError
      nil
    end

    def valid?(value)
      part = address_part(value)

      part.present? && part.length <= MAX_ADDRESS_LENGTH && part.match?(URI::MailTo::EMAIL_REGEXP)
    end
  end
end

# RFC 6238 TOTP (HMAC-SHA1, 30-second step, 6 digits) — pure stdlib, no gem.
class Totp
  STEP = 30
  DIGITS = 6
  BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

  class << self
    def generate_secret
      SecureRandom.bytes(20).unpack1("B*").scan(/.{5}/).map { |chunk| BASE32_ALPHABET[chunk.to_i(2)] }.join
    end
  end

  def initialize(secret)
    @secret = secret.to_s
  end

  def provisioning_uri(account:, issuer: "Departures")
    label = "#{ERB::Util.url_encode(issuer)}:#{ERB::Util.url_encode(account)}"
    "otpauth://totp/#{label}?secret=#{@secret}&issuer=#{ERB::Util.url_encode(issuer)}"
  end

  def code(at: Time.current)
    code_at(at.to_i / STEP)
  end

  # Returns the matched timestep so callers can persist it and refuse replays.
  def verify(code, at: Time.current, drift: 1)
    if code.to_s.match?(/\A\d{#{DIGITS}}\z/)
      timestep = at.to_i / STEP

      (-drift..drift).map { |offset| timestep + offset }.find do |candidate|
        ActiveSupport::SecurityUtils.secure_compare(code_at(candidate), code.to_s)
      end
    end
  end

  private
    def code_at(timestep)
      digest = OpenSSL::HMAC.digest("SHA1", decoded_secret, [ timestep ].pack("Q>"))
      offset = digest.bytes.last & 0x0f
      binary = ((digest.bytes[offset] & 0x7f) << 24) |
        (digest.bytes[offset + 1] << 16) |
        (digest.bytes[offset + 2] << 8) |
        digest.bytes[offset + 3]

      format("%0#{DIGITS}d", binary % 10**DIGITS)
    end

    def decoded_secret
      bits = @secret.upcase.delete("=").chars.map { |char| BASE32_ALPHABET.index(char).to_s(2).rjust(5, "0") }.join
      [ bits[0, bits.length - bits.length % 8] ].pack("B*")
    end
end

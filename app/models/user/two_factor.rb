module User::TwoFactor
  extend ActiveSupport::Concern

  RECOVERY_CODE_COUNT = 10

  included do
    encrypts :otp_secret
  end

  def two_factor_enabled?
    otp_enabled_at.present?
  end

  def two_factor_disabled?
    !two_factor_enabled?
  end

  def prepare_two_factor
    update! otp_secret: Totp.generate_secret
  end

  def enable_two_factor(code)
    timestep = otp_secret.present? && totp.verify(code)

    if timestep
      codes = build_recovery_codes
      update! otp_enabled_at: Time.current, otp_consumed_timestep: timestep, otp_recovery_codes: digest_codes(codes)
      codes
    else
      false
    end
  end

  def disable_two_factor
    update! otp_secret: nil, otp_enabled_at: nil, otp_consumed_timestep: nil, otp_recovery_codes: []
  end

  def verify_totp(code, at: Time.current)
    if two_factor_enabled?
      timestep = totp.verify(code, at: at)

      if timestep && timestep > otp_consumed_timestep.to_i
        update! otp_consumed_timestep: timestep
        true
      else
        false
      end
    else
      false
    end
  end

  def redeem_recovery_code(code)
    digest = Digest::SHA256.hexdigest(code.to_s.strip)

    if otp_recovery_codes.include?(digest)
      update! otp_recovery_codes: otp_recovery_codes - [ digest ]
      true
    else
      false
    end
  end

  def regenerate_recovery_codes
    codes = build_recovery_codes
    update! otp_recovery_codes: digest_codes(codes)
    codes
  end

  private
    def totp
      Totp.new(otp_secret)
    end

    def build_recovery_codes
      Array.new(RECOVERY_CODE_COUNT) { SecureRandom.hex(5) }
    end

    def digest_codes(codes)
      codes.map { |code| Digest::SHA256.hexdigest(code) }
    end
end

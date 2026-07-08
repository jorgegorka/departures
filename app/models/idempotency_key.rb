class IdempotencyKey < ApplicationRecord
  EXPIRY = 24.hours

  class MismatchError < StandardError; end

  belongs_to :api_key
  belongs_to :email

  scope :active, -> { where(expires_at: Time.current..) }
  scope :expired, -> { where(expires_at: ...Time.current) }

  validates :key, presence: true, uniqueness: { scope: :api_key_id }
  validates :fingerprint, presence: true

  class << self
    def replay_or_record(api_key:, key:, fingerprint:, &block)
      if key.blank?
        return block.call
      end

      existing = active.find_by(api_key: api_key, key: key)

      if existing
        replay(existing, fingerprint)
      else
        record(api_key, key, fingerprint, &block)
      end
    end

    def prune_expired
      expired.in_batches.delete_all
    end

    private
      def replay(existing, fingerprint)
        if existing.fingerprint == fingerprint
          existing.email
        else
          raise MismatchError
        end
      end

      def record(api_key, key, fingerprint)
        email = yield

        if email
          expired.where(api_key: api_key, key: key).delete_all
          create!(api_key: api_key, key: key, fingerprint: fingerprint, email: email, expires_at: EXPIRY.from_now)
        end

        email
      rescue ActiveRecord::RecordNotUnique
        replay(active.find_by!(api_key: api_key, key: key), fingerprint)
      end
  end
end

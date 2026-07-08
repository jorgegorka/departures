require "test_helper"

class IdempotencyKeyTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    @api_key = api_keys(:acme_full)
    @email = emails(:acme_welcome)
  end

  test "first call runs the block and records the result" do
    result = nil

    assert_difference -> { IdempotencyKey.count }, +1 do
      result = IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: "fp-1") { @email }
    end

    assert_equal @email, result
    record = IdempotencyKey.last
    assert_equal @email, record.email
    assert_in_delta 24.hours.from_now, record.expires_at, 5.seconds
  end

  test "matching replay returns the existing email without re-running the block" do
    IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: "fp-1") { @email }
    block_ran = false

    result = IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: "fp-1") do
      block_ran = true
    end

    assert_equal @email, result
    assert_not block_ran
  end

  test "fingerprint conflict raises MismatchError" do
    IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: "fp-1") { @email }

    assert_raises IdempotencyKey::MismatchError do
      IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: "fp-DIFFERENT") { @email }
    end
  end

  test "a blank key just runs the block" do
    assert_no_difference -> { IdempotencyKey.count } do
      assert_equal @email, IdempotencyKey.replay_or_record(api_key: @api_key, key: nil, fingerprint: "fp-1") { @email }
    end
  end

  test "a falsy block result is not recorded" do
    assert_no_difference -> { IdempotencyKey.count } do
      assert_equal false, IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: "fp-1") { false }
    end
  end

  test "keys are scoped per api key" do
    IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: "fp-1") { @email }
    other_email = emails(:acme_welcome).dup.tap { |e| e.public_id = nil; e.save! }

    result = IdempotencyKey.replay_or_record(api_key: api_keys(:acme_send_only), key: "req-1", fingerprint: "fp-1") { other_email }

    assert_equal other_email, result
  end

  test "expired keys are replaced, not replayed" do
    IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: "fp-1") { @email }
    IdempotencyKey.last.update_columns(expires_at: 1.hour.ago)
    replacement = emails(:acme_welcome).dup.tap { |e| e.public_id = nil; e.save! }

    result = IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: "fp-2") { replacement }

    assert_equal replacement, result
  end

  test "prune_expired removes only expired rows" do
    IdempotencyKey.replay_or_record(api_key: @api_key, key: "old", fingerprint: "fp") { @email }
    IdempotencyKey.replay_or_record(api_key: @api_key, key: "fresh", fingerprint: "fp") { @email }
    IdempotencyKey.find_by(key: "old").update_columns(expires_at: 1.hour.ago)

    IdempotencyKey.prune_expired

    assert_equal %w[ fresh ], IdempotencyKey.pluck(:key)
  end
end

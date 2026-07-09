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
      result = IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: -> { "fp-1" }) { @email }
    end

    assert_equal @email, result
    record = IdempotencyKey.last
    assert_equal @email, record.email
    assert_in_delta 24.hours.from_now, record.expires_at, 5.seconds
  end

  test "matching replay returns the existing email without re-running the block" do
    IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: -> { "fp-1" }) { @email }
    block_ran = false

    result = IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: -> { "fp-1" }) do
      block_ran = true
    end

    assert_equal @email, result
    assert_not block_ran
  end

  test "fingerprint conflict raises MismatchError" do
    IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: -> { "fp-1" }) { @email }

    assert_raises IdempotencyKey::MismatchError do
      IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: -> { "fp-DIFFERENT" }) { @email }
    end
  end

  test "a blank key just runs the block" do
    assert_no_difference -> { IdempotencyKey.count } do
      assert_equal @email, IdempotencyKey.replay_or_record(api_key: @api_key, key: nil, fingerprint: -> { "fp-1" }) { @email }
    end
  end

  test "a falsy block result is not recorded" do
    assert_no_difference -> { IdempotencyKey.count } do
      assert_equal false, IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: -> { "fp-1" }) { false }
    end
  end

  test "keys are scoped per api key" do
    IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: -> { "fp-1" }) { @email }
    other_email = emails(:acme_welcome).dup.tap { |e| e.public_id = nil; e.save! }

    result = IdempotencyKey.replay_or_record(api_key: api_keys(:acme_send_only), key: "req-1", fingerprint: -> { "fp-1" }) { other_email }

    assert_equal other_email, result
  end

  test "expired keys are replaced, not replayed" do
    IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: -> { "fp-1" }) { @email }
    IdempotencyKey.last.update_columns(expires_at: 1.hour.ago)
    replacement = emails(:acme_welcome).dup.tap { |e| e.public_id = nil; e.save! }

    result = IdempotencyKey.replay_or_record(api_key: @api_key, key: "req-1", fingerprint: -> { "fp-2" }) { replacement }

    assert_equal replacement, result
  end

  test "a losing race rolls back its own email and replays the winner" do
    # The winner request has already committed its email + key row.
    IdempotencyKey.replay_or_record(api_key: @api_key, key: "race", fingerprint: -> { "fp-1" }) { @email }
    email_count = Email.count

    # Simulate the loser: it raced past the initial lookup (which misses, as if
    # the winner's key row landed just after find_by), built its own email, then
    # its key insert hit the unique index and the DB raised RecordNotUnique
    # (a real race clears the AR uniqueness validation because the winner's row
    # is not yet visible, so only the index catches it). The rescue then
    # re-queries via active and replays the winner, so active must miss on the
    # first call but see the real row afterwards.
    real_active = IdempotencyKey.method(:active)
    miss = Object.new
    def miss.find_by(*) = nil
    calls = 0
    loser_email = nil

    IdempotencyKey.define_singleton_method(:active) do
      (calls += 1) == 1 ? miss : real_active.call
    end
    IdempotencyKey.define_singleton_method(:create!) do |*|
      raise ActiveRecord::RecordNotUnique, "index_idempotency_keys_on_api_key_id_and_key"
    end

    result =
      begin
        IdempotencyKey.replay_or_record(api_key: @api_key, key: "race", fingerprint: -> { "fp-1" }) do
          loser_email = emails(:acme_welcome).dup.tap { |e| e.public_id = nil; e.save! }
          loser_email
        end
      ensure
        IdempotencyKey.define_singleton_method(:active) { real_active.call }
        IdempotencyKey.singleton_class.send(:remove_method, :create!)
      end

    # The winner's email is replayed, and the loser's email was rolled back:
    # exactly the emails we started with survive.
    assert_equal @email, result
    assert_nil Email.find_by(id: loser_email.id)
    assert_equal email_count, Email.count
    assert_equal 1, IdempotencyKey.where(api_key: @api_key, key: "race").count
  end

  test "prune_expired removes only expired rows" do
    IdempotencyKey.replay_or_record(api_key: @api_key, key: "old", fingerprint: -> { "fp" }) { @email }
    IdempotencyKey.replay_or_record(api_key: @api_key, key: "fresh", fingerprint: -> { "fp" }) { @email }
    IdempotencyKey.find_by(key: "old").update_columns(expires_at: 1.hour.ago)

    IdempotencyKey.prune_expired

    assert_equal %w[ fresh ], IdempotencyKey.pluck(:key)
  end
end

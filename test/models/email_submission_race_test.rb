require "test_helper"

# The idempotency race must be observed with production transaction semantics:
# under transactional fixtures the fixture transaction is outermost, so the
# deferred SendEmailJob enqueue attaches outside IdempotencyKey.record's
# savepoint and its rollback cannot drop it — which is exactly what this test
# must prove happens for real. Hence use_transactional_tests = false and a
# concurrent winner committed from a second connection.
class EmailSubmissionRaceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  self.use_transactional_tests = false

  setup do
    Current.session = sessions(:owner)
  end

  teardown do
    IdempotencyKey.delete_all
    EmailRecipient.delete_all
    EmailAttachment.delete_all
    Email.delete_all
    Current.reset
  end

  test "losing an idempotency race returns the winner, rolls back the loser email, and enqueues nothing" do
    api_key = api_keys(:acme_full)
    winner = Email.create!(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", subject: "Winner", html_body: "<p>w</p>")

    result = nil
    assert_no_difference -> { Email.count } do
      assert_no_enqueued_jobs only: SendEmailJob do
        result = IdempotencyKey.replay_or_record(api_key: api_key, key: "race-1", fingerprint: -> { "fp-1" }) do
          # A concurrent request claims the key on its own connection and
          # commits, landing between our lookup and our insert.
          Thread.new do
            IdempotencyKey.create!(api_key: api_key, key: "race-1", fingerprint: "fp-1",
              email: winner, expires_at: 1.hour.from_now)
          end.join

          delivery_submission.save
        end
      end
    end

    assert_equal winner, result
  end

  private
    def delivery_submission(**overrides)
      EmailSubmission.new({ project: projects(:acme_default), source: sources(:acme_production),
        from: "hello@acme.com", to: [ "user@example.com" ], subject: "Hi", html: "<p>Hi</p>" }.merge(overrides))
    end
end

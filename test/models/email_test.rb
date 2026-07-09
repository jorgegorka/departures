require "test_helper"

class EmailTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "public_id is assigned before create with the em_ prefix" do
    email = projects(:acme_default).emails.create!(source: sources(:acme_production),
      from: "hello@acme.com", subject: "Hi")

    assert_match(/\Aem_[a-zA-Z0-9]{24}\z/, email.public_id)
  end

  test "workspace defaults to the project's workspace" do
    email = projects(:acme_default).emails.create!(source: sources(:acme_production),
      from: "hello@acme.com", subject: "Hi")

    assert_equal workspaces(:acme), email.workspace
  end

  test "recipients and attachments are destroyed with the email" do
    wipe_send_domain
    email = projects(:acme_default).emails.create!(source: sources(:acme_production),
      from: "hello@acme.com", subject: "Hi")
    email.recipients.create!(kind: "to", address: "user@example.com")
    email.attachments.create!(filename: "a.pdf", byte_size: 10)

    assert_difference -> { EmailRecipient.count } => -1, -> { EmailAttachment.count } => -1 do
      email.destroy
    end
  end

  test "destroying an email destroys its idempotency keys" do
    email = emails(:acme_welcome)
    email.idempotency_keys.create!(api_key: api_keys(:acme_full), key: "req-1",
      fingerprint: "fp-1", expires_at: IdempotencyKey::EXPIRY.from_now)

    assert_difference -> { IdempotencyKey.count }, -1 do
      email.destroy!
    end
  end

  test "indexed_by maps UI params onto status scopes" do
    scope = projects(:acme_default).emails

    assert_includes scope.indexed_by("delivered"), emails(:acme_delivered)
    assert_not_includes scope.indexed_by("delivered"), emails(:acme_opened)
    assert_includes scope.indexed_by("bounced"), emails(:acme_hard_bounce)
    assert_includes scope.indexed_by("bounced"), emails(:acme_soft_bounce)
    assert_includes scope.indexed_by("complained"), emails(:acme_complained)
    assert_includes scope.indexed_by("failed"), emails(:acme_failed)
    assert_includes scope.indexed_by("everything-else"), emails(:acme_welcome)
  end

  test "hard and soft bounce scopes split on bounce_type and exclude unclassified" do
    unclassified = emails(:acme_complained)
    unclassified.update_columns(status: "bounced", bounce_type: nil)

    assert_equal [ emails(:acme_hard_bounce) ], projects(:acme_default).emails.hard_bounced.to_a
    assert_equal [ emails(:acme_soft_bounce) ], projects(:acme_default).emails.soft_bounced.to_a
  end

  test "in_time_range windows on created_at and passes unknown params through" do
    scope = projects(:acme_default).emails

    assert_includes scope.in_time_range("1h"), emails(:acme_sent)
    assert_not_includes scope.in_time_range("1h"), emails(:acme_delivered)
    assert_includes scope.in_time_range("24h"), emails(:acme_delivered)
    assert_not_includes scope.in_time_range("7d"), emails(:acme_complained)
    assert_includes scope.in_time_range("30d"), emails(:acme_complained)
    assert_not_includes scope.in_time_range("30d"), emails(:acme_ancient)
    assert_includes scope.in_time_range(nil), emails(:acme_ancient)
  end

  test "sorted_by orders oldest or newest first" do
    scope = projects(:acme_default).emails

    assert_equal scope.order(created_at: :asc, id: :asc).first, scope.sorted_by("oldest").first
    assert_equal scope.order(created_at: :desc, id: :desc).first, scope.sorted_by("whatever").first
  end

  test "search matches subject, from, public_id and recipient address" do
    scope = projects(:acme_default).emails

    assert_includes scope.search("invoice"), emails(:acme_sent)
    assert_includes scope.search("em_fixturedelivered000001"), emails(:acme_delivered)
    assert_includes scope.search("hello@acme.com"), emails(:acme_sent)
    assert_includes scope.search("searchme@customer"), emails(:acme_delivered)
    assert_not_includes scope.search("searchme@customer"), emails(:acme_sent)
    assert_equal scope.count, scope.search("").count
  end

  test "search treats LIKE metacharacters literally" do
    assert_empty projects(:acme_default).emails.search("100%")
  end

  test "preloaded eager-loads the associations the feed renders" do
    email = Email.preloaded.find(emails(:acme_delivered).id)

    assert email.recipients.loaded?
    assert email.events.loaded?
    assert email.association(:source).loaded?
  end
end

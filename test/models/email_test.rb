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
    email = emails(:acme_welcome)
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
end

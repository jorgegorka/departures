require "test_helper"

class EmailRetentionTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    wipe_send_domain
    @source = sources(:acme_production) # retention_days: 30
  end

  test "prune_expired destroys emails past the source retention window, their children, and their archived MIME" do
    expired = create_email(subject: "Old", created_at: 31.days.ago)
    expired.recipients.create!(address: "old@example.com", kind: "to")
    expired.events.create!(event_type: "delivery", occurred_at: 31.days.ago)
    Email::MimeStore.write(expired, "MIME-Version: 1.0\r\n\r\nold")
    eml_path = Email::MimeStore.root.join(expired.mime_path)

    kept = create_email(subject: "Recent", created_at: 29.days.ago)

    assert eml_path.exist?

    Email.prune_expired

    assert_not Email.exists?(expired.id)
    assert_not eml_path.exist?
    assert_equal 0, EmailRecipient.where(email_id: expired.id).count
    assert_equal 0, EmailEvent.where(email_id: expired.id).count
    assert Email.exists?(kept.id)
  end

  test "prune_expired applies each source's own retention window" do
    @source.update!(retention_days: 7)
    long_retention = sources(:globex_production) # retention_days: 30, other workspace

    short_lived = create_email(subject: "Short window", created_at: 8.days.ago)
    long_lived = Email.create!(project: long_retention.project, source: long_retention,
      from: "hello@globex.com", subject: "Long window", html_body: "<p>hi</p>", created_at: 8.days.ago)

    Email.prune_expired

    assert_not Email.exists?(short_lived.id)
    assert Email.exists?(long_lived.id)
  end

  test "prune_expired leaves emails without an archived MIME untouched by the file cleanup" do
    expired = create_email(subject: "No file", created_at: 31.days.ago)
    assert_nil expired.mime_path

    Email.prune_expired

    assert_not Email.exists?(expired.id)
  end

  private
    def create_email(subject:, created_at:)
      Email.create!(project: @source.project, source: @source, from: "hello@acme.com",
        subject: subject, html_body: "<p>hi</p>", created_at: created_at)
    end
end

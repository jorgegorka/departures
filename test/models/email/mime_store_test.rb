require "test_helper"

class Email::MimeStoreTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    # Freshly created email (random public_id) — parallel test workers share the
    # filesystem, so fixture emails' fixed public_ids would collide across workers.
    @email = Email.create!(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", subject: "Hi", html_body: "<p>Hi</p>")
  end

  teardown do
    Email::MimeStore.delete(@email)
  end

  test "root points at tmp storage in the test env" do
    assert_equal Rails.root.join("tmp", "storage", "emails"), Email::MimeStore.root
  end

  test "write stores the file and records the relative path and byte size" do
    eml = "Subject: héllo\r\n\r\nBody"

    Email::MimeStore.write(@email, eml)

    assert_equal "#{@email.project_id}/#{@email.public_id}.eml", @email.mime_path
    assert_equal eml.bytesize, @email.mime_size
    assert_operator @email.mime_size, :>, eml.length, "must count bytes, not characters"
    assert Email::MimeStore.root.join(@email.mime_path).exist?
  end

  test "read round-trips the exact stored bytes" do
    eml = "raw \xC3\xA9 bytes".b
    Email::MimeStore.write(@email, eml)

    assert_equal eml, Email::MimeStore.read(@email)
  end

  test "delete removes the file and tolerates calling twice" do
    Email::MimeStore.write(@email, "bytes")
    path = Email::MimeStore.root.join(@email.mime_path)

    Email::MimeStore.delete(@email)

    assert_not path.exist?
    assert_nothing_raised { Email::MimeStore.delete(@email) }
  end

  test "delete is a no-op when nothing was ever stored" do
    assert_nothing_raised { Email::MimeStore.delete(@email) }
  end
end

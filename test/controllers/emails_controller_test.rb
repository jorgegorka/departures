require "test_helper"

class EmailsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
  end

  test "index lists and filters the current project's emails" do
    get emails_url

    assert_response :success
    assert_select "body", text: /April invoice/
    assert_select "body", { text: /Globex says hi/, count: 0 }

    get emails_url(filter: "failed")

    assert_select "body", text: /Never left/
    assert_select "body", { text: /April invoice/, count: 0 }
  end

  test "show renders the inspector by public_id" do
    get email_url(emails(:acme_delivered))

    assert_response :success
    assert_select "body", text: /Welcome aboard/
    assert_select "body", text: /searchme@customer.example/
  end

  test "cross-tenant emails 404" do
    get email_url(emails(:globex_delivered))

    assert_response :not_found
  end

  test "preview renders the html body under a strict CSP" do
    get preview_email_url(emails(:acme_delivered))

    assert_response :success
    assert_includes response.body, "<p>Hi!</p>"
    assert_equal "default-src 'none'; img-src * data:; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'",
      response.headers["Content-Security-Policy"]
    assert_equal "SAMEORIGIN", response.headers["X-Frame-Options"]
  end

  test "preview falls back to the text body" do
    get preview_email_url(emails(:acme_sent))

    assert_response :success
    assert_includes response.body, "Invoice attached"
  end

  test "raw sends the archived eml" do
    email = create_stored_email

    get raw_email_url(email)

    assert_response :success
    assert_equal "message/rfc822", response.media_type
    assert_includes response.body, "X-Departures-Id: #{email.public_id}"
  end

  test "raw 404s when the mime was pruned" do
    get raw_email_url(emails(:acme_delivered))

    assert_response :not_found
  end

  private
    def create_stored_email
      EmailSubmission.new(project: projects(:acme_default), source: sources(:acme_production),
        from: "hello@acme.com", to: [ "raw@example.com" ], subject: "Raw me", text: "Body").save
    end
end

require "test_helper"

class Emails::ResendsControllerTest < ActionDispatch::IntegrationTest
  test "resending queues a copy" do
    sign_in_as users(:owner)
    email = EmailSubmission.new(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", to: [ "again@example.com" ], subject: "Once more", text: "Body").save

    assert_difference -> { Email.count }, +1 do
      post email_resend_url(email)
    end

    assert_redirected_to email_url(Email.order(:id).last)
  end

  test "a suppressed recipient blocks the resend with an alert" do
    sign_in_as users(:owner)
    email = EmailSubmission.new(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", to: [ "will-block@example.com" ], subject: "Nope", text: "Body").save
    Suppression.record(projects(:acme_default), "will-block@example.com", reason: "complaint")

    assert_no_difference -> { Email.count } do
      post email_resend_url(email)
    end

    assert_redirected_to email_url(email)
    assert_equal "Email could not be resent — recipients may be suppressed.", flash[:alert]
  end

  test "requires the send capability" do
    sign_in_as users(:read_only)
    post email_resend_url(emails(:acme_delivered))

    assert_response :forbidden
  end

  test "cross-tenant resends 404" do
    sign_in_as users(:owner)
    post email_resend_url(emails(:globex_delivered))

    assert_response :not_found
  end
end

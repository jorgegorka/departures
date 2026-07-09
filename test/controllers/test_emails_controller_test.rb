require "test_helper"

class TestEmailsControllerTest < ActionDispatch::IntegrationTest
  test "new renders the form" do
    sign_in_as users(:owner)
    get new_test_email_url

    assert_response :success
    assert_select "form[action=?]", test_emails_path
  end

  test "create queues a test email through the full submission pipeline" do
    sign_in_as users(:owner)

    assert_difference -> { Email.count }, +1 do
      assert_enqueued_with(job: SendEmailJob) do
        post test_emails_url, params: { email_submission: {
          from: "hello@acme.com", to: "me@example.com", subject: "Test send", text: "It works" } }
      end
    end

    assert_redirected_to email_url(Email.order(:id).last)
  end

  test "validation errors re-render the form" do
    sign_in_as users(:owner)

    assert_no_difference -> { Email.count } do
      post test_emails_url, params: { email_submission: { from: "", to: "", subject: "", text: "" } }
    end

    assert_response :unprocessable_entity
    assert_select ".txt-negative"
  end

  test "requires the send capability" do
    sign_in_as users(:read_only)
    get new_test_email_url
    assert_response :forbidden

    post test_emails_url, params: { email_submission: { from: "hello@acme.com", to: "d@e.f", subject: "x", text: "y" } }
    assert_response :forbidden
  end
end

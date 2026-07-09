require "test_helper"

class Bounces::RetriesControllerTest < ActionDispatch::IntegrationTest
  test "retrying re-queues soft bounces and reports the count" do
    sign_in_as users(:owner)
    Email.soft_bounced.update_all(bounce_type: nil) # unclassify fixture rows so only the controlled email retries
    email = EmailSubmission.new(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", to: [ "retry@example.com" ], subject: "Bounced softly", text: "Body").save
    email.update_columns(status: "bounced", bounce_type: "transient")

    assert_difference -> { Email.count }, +1 do
      post bounces_retry_url
    end

    assert_redirected_to bounces_url
    assert_match(/1 email/, flash[:notice])
  end

  test "requires the send capability" do
    sign_in_as users(:read_only)
    post bounces_retry_url

    assert_response :forbidden
  end

  test "404s when the workspace has no active project" do
    sign_in_as users(:owner)
    projects(:acme_default).update_columns(archived_at: Time.current)

    post bounces_retry_url

    assert_response :not_found
  end
end

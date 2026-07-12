require "test_helper"

class ContentSecurityPolicyTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
  end

  test "dashboard responses carry the global nonce-based policy" do
    get emails_url

    policy = response.headers["Content-Security-Policy"]
    assert_includes policy, "default-src 'self'"
    assert_includes policy, "frame-ancestors 'none'"
    assert_includes policy, "object-src 'none'"
    assert_match(/script-src 'self' 'nonce-[^']+'/, policy)
    assert_match(/style-src 'self' 'nonce-[^']+'/, policy)
  end

  test "email preview keeps its own stricter policy" do
    get preview_email_url(emails(:acme_delivered))

    assert_equal EmailsController::PREVIEW_CSP, response.headers["Content-Security-Policy"]
  end
end

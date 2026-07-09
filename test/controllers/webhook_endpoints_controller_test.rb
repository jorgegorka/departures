require "test_helper"

class WebhookEndpointsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
  end

  test "index lists only the current project's endpoints" do
    get webhook_endpoints_url

    assert_response :success
    assert_match "hooks.acme.com", response.body
    assert_no_match "hooks.globex.com", response.body
  end

  test "create reveals the secret exactly once" do
    assert_difference -> { projects(:acme_default).webhook_endpoints.count }, +1 do
      post webhook_endpoints_url, params: { webhook_endpoint: { url: "https://example.com/hook",
        events: [ "bounce", "complaint" ] } }
    end

    assert_response :success
    assert_match(/whsec_[A-Za-z0-9]{32}/, response.body)

    get webhook_endpoint_url(WebhookEndpoint.last)
    assert_no_match WebhookEndpoint.last.secret, response.body
  end

  test "create re-renders on validation errors" do
    post webhook_endpoints_url, params: { webhook_endpoint: { url: "http://insecure.example.com", events: [ "bounce" ] } }

    assert_response :unprocessable_entity
  end

  test "show renders the delivery log" do
    webhook_endpoints(:acme_all).deliveries.create!(event_type: "bounce", status: "succeeded",
      http_status: 200, latency_ms: 42, payload: {})
    webhook_endpoints(:acme_all).deliveries.create!(event_type: "bounce", status: "failed",
      http_status: 500, latency_ms: 61, payload: {})

    get webhook_endpoint_url(webhook_endpoints(:acme_all))

    assert_response :success
    assert_match "50.0", response.body
  end

  test "update toggles subscriptions and active state" do
    patch webhook_endpoint_url(webhook_endpoints(:acme_all)), params: { webhook_endpoint: {
      active: false, events: [ "bounce" ] } }

    assert_redirected_to webhook_endpoints_url
    assert_not webhook_endpoints(:acme_all).reload.active
  end

  test "destroy removes the endpoint" do
    assert_difference -> { WebhookEndpoint.count }, -1 do
      delete webhook_endpoint_url(webhook_endpoints(:acme_inactive))
    end
  end

  test "cross-tenant endpoints 404" do
    get webhook_endpoint_url(webhook_endpoints(:globex_bounces))
    assert_response :not_found
  end

  test "mutations require the manage_webhooks capability" do
    sign_in_as users(:sender)

    post webhook_endpoints_url, params: { webhook_endpoint: { url: "https://example.com/hook", events: [ "bounce" ] } }
    assert_response :forbidden

    delete webhook_endpoint_url(webhook_endpoints(:acme_all))
    assert_response :forbidden
  end
end

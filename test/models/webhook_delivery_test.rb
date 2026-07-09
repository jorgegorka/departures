require "test_helper"

class WebhookDeliveryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Current.session = sessions(:owner)
    @delivery = webhook_endpoints(:acme_all).deliveries.create!(event_type: "bounce",
      payload: { "event" => "bounce" })
  end

  test "workspace defaults from the endpoint" do
    assert_equal workspaces(:acme), @delivery.workspace
    assert @delivery.pending?
  end

  test "a 2xx response marks the delivery succeeded and records the attempt" do
    @delivery.stub(:post_payload, http_response(Net::HTTPOK, "200", "ok")) do
      assert @delivery.deliver
    end

    assert @delivery.succeeded?
    assert_equal 1, @delivery.attempts
    assert_equal 200, @delivery.http_status
    assert_equal "ok", @delivery.response_body
    assert @delivery.latency_ms.present?
    assert @delivery.last_attempted_at.present?
  end

  test "a non-2xx response records the attempt and raises for retry" do
    @delivery.stub(:post_payload, http_response(Net::HTTPInternalServerError, "500", "boom")) do
      assert_raises WebhookDelivery::DeliveryError do
        @delivery.deliver
      end
    end

    assert @delivery.pending?, "stays pending so the job retry can run again"
    assert_equal 1, @delivery.attempts
    assert_equal 500, @delivery.http_status
    assert_equal "boom", @delivery.response_body
  end

  test "network errors record the attempt and raise for retry" do
    raising = -> { raise SocketError, "getaddrinfo failed" }

    @delivery.stub(:post_payload, raising) do
      assert_raises WebhookDelivery::DeliveryError do
        @delivery.deliver
      end
    end

    assert @delivery.pending?
    assert_equal 1, @delivery.attempts
    assert_nil @delivery.http_status
    assert_match "getaddrinfo", @delivery.response_body
  end

  test "a settled delivery does not post again" do
    @delivery.update!(status: "succeeded")

    never_called = -> { flunk "must not post a settled delivery" }
    @delivery.stub(:post_payload, never_called) do
      assert_not @delivery.deliver
    end
  end

  test "signature is the documented HMAC over timestamp dot body" do
    body = { "event" => "bounce" }.to_json
    expected = OpenSSL::HMAC.hexdigest("SHA256", webhook_endpoints(:acme_all).secret, "1700000000.#{body}")

    assert_equal expected, @delivery.signature(1_700_000_000, body)
  end

  test "response bodies are truncated" do
    @delivery.stub(:post_payload, http_response(Net::HTTPOK, "200", "x" * 5_000)) do
      @delivery.deliver
    end

    assert_operator @delivery.response_body.length, :<=, 1_000
  end

  test "delivery to a loopback host is blocked before any request is made" do
    delivery = delivery_to("https://localhost/hook")

    assert_raises WebhookDelivery::DeliveryError do
      delivery.deliver
    end

    assert delivery.pending?
    assert_equal 1, delivery.attempts
    assert_nil delivery.http_status
    assert_match(/blocked address/, delivery.response_body)
  end

  test "delivery to a private IP literal is blocked before any request is made" do
    delivery = delivery_to("https://10.0.0.5/hook")

    assert_raises WebhookDelivery::DeliveryError do
      delivery.deliver
    end

    assert delivery.pending?
    assert_equal 1, delivery.attempts
    assert_nil delivery.http_status
    assert_match(/blocked address/, delivery.response_body)
  end

  test "deliver_later enqueues on the webhooks queue" do
    assert_enqueued_with(job: DeliverWebhookJob, args: [ @delivery ], queue: "webhooks") do
      @delivery.deliver_later
    end
  end

  private
    def delivery_to(url)
      endpoint = WebhookEndpoint.create!(project: webhook_endpoints(:acme_all).project,
        url: url, events: %w[ bounce ])
      endpoint.deliveries.create!(event_type: "bounce", payload: { "event" => "bounce" })
    end

    def http_response(klass, code, body)
      response = klass.new("1.1", code, "")
      response.instance_variable_set(:@read, true)
      response.instance_variable_set(:@body, body)
      response
    end
end

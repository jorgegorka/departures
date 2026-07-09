require "test_helper"

class WebhookEndpointTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "creating an endpoint generates an encrypted whsec_ secret" do
    endpoint = projects(:acme_default).webhook_endpoints.create!(url: "https://example.com/hook",
      events: %w[ bounce ])

    assert_match(/\Awhsec_[A-Za-z0-9]{32}\z/, endpoint.secret)
    assert_equal workspaces(:acme), endpoint.workspace
    assert endpoint.active
  end

  test "url must be https" do
    endpoint = projects(:acme_default).webhook_endpoints.build(url: "http://example.com/hook",
      events: %w[ bounce ])

    assert_not endpoint.valid?
    assert endpoint.errors[:url].any?
  end

  test "url without a host is invalid" do
    endpoint = projects(:acme_default).webhook_endpoints.build(url: "https://",
      events: %w[ bounce ])

    assert_not endpoint.valid?
    assert endpoint.errors[:url].any?
  end

  test "unparseable url is invalid" do
    endpoint = projects(:acme_default).webhook_endpoints.build(url: "https://exa mple.com/hook",
      events: %w[ bounce ])

    assert_not endpoint.valid?
    assert endpoint.errors[:url].any?
  end

  test "events must be a non-empty subset of the known types" do
    endpoint = projects(:acme_default).webhook_endpoints.build(url: "https://example.com/hook", events: [])
    assert_not endpoint.valid?

    endpoint.events = %w[ bounce made_up ]
    assert_not endpoint.valid?

    endpoint.events = %w[ bounce complaint ]
    assert endpoint.valid?
  end

  test "events setter drops the blanks checkbox forms submit" do
    endpoint = projects(:acme_default).webhook_endpoints.build(url: "https://example.com/hook",
      events: [ "", "bounce" ])

    assert_equal %w[ bounce ], endpoint.events
  end

  test "subscribed_to? and the active scope drive fan-out selection" do
    assert webhook_endpoints(:acme_all).subscribed_to?("bounce")
    assert_not webhook_endpoints(:acme_all).subscribed_to?("reject")

    assert_includes projects(:acme_default).webhook_endpoints.active, webhook_endpoints(:acme_all)
    assert_not_includes projects(:acme_default).webhook_endpoints.active, webhook_endpoints(:acme_inactive)
  end
end

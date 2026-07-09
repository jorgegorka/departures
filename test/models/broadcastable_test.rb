require "test_helper"
require "turbo/broadcastable/test_helper"

class BroadcastableTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  setup do
    Current.session = sessions(:owner)
    @email = Email.create!(project: projects(:acme_default), source: sources(:acme_production),
      from: "hello@acme.com", subject: "Live", html_body: "<p>hi</p>")
  end

  test "a successful status advance broadcasts a refresh to the project activity stream" do
    streams = capture_turbo_stream_broadcasts([ @email.project, :activity ]) do
      @email.apply_event("delivery")
    end

    assert_equal "refresh", streams.sole["action"]
  end

  test "a rejected advance broadcasts nothing" do
    @email.apply_event("delivery")

    streams = capture_turbo_stream_broadcasts([ @email.project, :activity ]) do
      @email.mark_sending
    end

    assert_empty streams
  end
end

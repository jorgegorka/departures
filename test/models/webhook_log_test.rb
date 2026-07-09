require "test_helper"

class WebhookLogTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "workspace defaults from the source" do
    log = sources(:acme_production).webhook_logs.create!(message_type: "Notification", payload: { "Type" => "Notification" })

    assert_equal workspaces(:acme), log.workspace
    assert_equal "received", log.status
  end

  test "status is constrained to the known set" do
    log = sources(:acme_production).webhook_logs.build(payload: {}, status: "bogus")

    assert_not log.valid?
    assert log.errors[:status].any?
  end
end

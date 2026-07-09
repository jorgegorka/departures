require "test_helper"

class ProcessSesEventJobTest < ActiveJob::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "performing the job processes the log" do
    log = sources(:acme_production).webhook_logs.create!(message_type: "Notification",
      payload: { "Type" => "Notification", "Message" => { "eventType" => "Delivery",
        "mail" => { "messageId" => "no-such-message" } }.to_json })

    perform_enqueued_jobs do
      ProcessSesEventJob.perform_later(log)
    end

    assert log.reload.unmatched?
  end
end

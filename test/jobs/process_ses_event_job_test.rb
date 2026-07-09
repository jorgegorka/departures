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

  test "a networking failure retries five times then marks the log failed" do
    subscribe_url = "https://sns.eu-west-1.amazonaws.com/?Action=ConfirmSubscription&Token=tok"
    log = sources(:acme_production).webhook_logs.create!(message_type: "SubscriptionConfirmation",
      payload: { "Type" => "SubscriptionConfirmation", "SubscribeURL" => subscribe_url })

    attempts = 0
    Net::HTTP.stub :get_response, ->(_uri) { attempts += 1; raise SocketError, "getaddrinfo failed" } do
      perform_enqueued_jobs do
        ProcessSesEventJob.perform_later(log)
      end
    end

    assert_equal 5, attempts
    assert log.reload.failed?
    assert_includes log.error, "getaddrinfo"
  end
end

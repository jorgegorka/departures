require "test_helper"

class DeliverWebhookJobTest < ActiveJob::TestCase
  setup do
    Current.session = sessions(:owner)
    @delivery = webhook_endpoints(:acme_all).deliveries.create!(event_type: "bounce",
      payload: { "event" => "bounce" })
  end

  test "runs on the webhooks queue and delegates to deliver" do
    assert_equal "webhooks", DeliverWebhookJob.new(@delivery).queue_name

    @delivery.stub(:deliver, true) do
      DeliverWebhookJob.perform_now(@delivery)
    end
  end

  test "mark_failed settles the delivery after exhausted retries" do
    @delivery.mark_failed

    assert @delivery.failed?
  end
end

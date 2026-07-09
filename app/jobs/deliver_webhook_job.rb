class DeliverWebhookJob < ApplicationJob
  queue_as :webhooks

  retry_on WebhookDelivery::DeliveryError, wait: :polynomially_longer, attempts: 3 do |job, _error|
    job.arguments.first.mark_failed
  end

  def perform(webhook_delivery)
    webhook_delivery.deliver
  end
end

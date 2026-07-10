class PruneRetentionJob < ApplicationJob
  queue_as :default

  def perform
    Email.prune_expired
    WebhookLog.prune
    WebhookDelivery.prune
    IdempotencyKey.prune_expired
    Invitation.prune_expired
  end
end

# Live-activity broadcasting for project-owned records: a refresh stream
# action on [project, :activity], morphed by any subscribed dashboard view.
module Broadcastable
  extend ActiveSupport::Concern

  # Deferred to after-commit so a broadcast fired from inside the ingestion
  # transaction (WebhookLog#ingest_notification) never escapes it: Solid Cable's
  # production cable DB is separate, so a synchronous broadcast would survive
  # rollback and reach subscribers pre-commit with no post-commit rebroadcast.
  # Rails 8.1 runs the block immediately when no real/joinable transaction is
  # open, so callers outside a transaction keep synchronous semantics.
  def broadcast_activity
    ActiveRecord.after_all_transactions_commit do
      broadcast_refresh_to(project, :activity)
    end
  end
end

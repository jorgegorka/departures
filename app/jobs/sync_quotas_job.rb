class SyncQuotasJob < ApplicationJob
  queue_as :default

  def perform
    Source.sync_all_quotas
  end
end

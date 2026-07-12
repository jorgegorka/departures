require "test_helper"

class SyncQuotasJobTest < ActiveSupport::TestCase
  test "perform refreshes stale quotas for every source" do
    acme = sources(:acme_production)
    globex = sources(:globex_production)
    acme.update!(last_quota_checked_at: 2.days.ago)
    globex.update!(last_quota_checked_at: 2.days.ago)

    SyncQuotasJob.perform_now

    assert acme.reload.quota_fresh?
    assert globex.reload.quota_fresh?
  end
end

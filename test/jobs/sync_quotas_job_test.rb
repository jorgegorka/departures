require "test_helper"

class SyncQuotasJobTest < ActiveSupport::TestCase
  test "perform refreshes stale quotas for every source" do
    source = sources(:acme_production)
    source.update!(last_quota_checked_at: 2.days.ago)

    SyncQuotasJob.perform_now

    assert source.reload.quota_fresh?
  end
end

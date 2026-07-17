require "test_helper"

class Source::QuotaTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    @source = sources(:acme_production)
    @source.ses_client = Aws::SESV2::Client.new(stub_responses: true)
  end

  test "sync_quota stores the account quota and stamps the check time" do
    @source.ses_client.stub_responses(:get_account,
      send_quota: { max_24_hour_send: 200.0, max_send_rate: 1.0, sent_last_24_hours: 7.0 },
      sending_enabled: true, production_access_enabled: false)
    @source.update!(last_quota: nil, last_quota_checked_at: nil)

    assert @source.sync_quota
    assert_equal 200.0, @source.last_quota["max_24_hour_send"]
    assert_equal 7.0, @source.last_quota["sent_last_24_hours"]
    assert_equal false, @source.last_quota["production_access"]
    assert @source.last_quota_checked_at.present?
  end

  test "sync_quota returns false and keeps the stale stamp on SES errors" do
    @source.ses_client.stub_responses(:get_account, "TooManyRequestsException")
    @source.update!(last_quota_checked_at: nil)

    assert_not @source.sync_quota
    assert_nil @source.reload.last_quota_checked_at
  end

  test "sync_quota returns false when SES is unreachable" do
    @source.ses_client.stub_responses(:get_account, Seahorse::Client::NetworkingError.new(Errno::ECONNRESET.new))
    @source.update!(last_quota_checked_at: nil)

    assert_not @source.sync_quota
    assert_nil @source.reload.last_quota_checked_at
  end

  test "sync_quota backs off after a failure and does not re-hit SES within the window" do
    @source.ses_client.stub_responses(:get_account, Seahorse::Client::NetworkingError.new(Errno::ECONNRESET.new))

    assert_not @source.sync_quota
    assert_not @source.sync_quota

    assert_equal 1, @source.ses_client.api_requests.count { |request| request[:operation_name] == :get_account }
  end

  test "quota_stale? uses the six hour TTL" do
    @source.update!(last_quota_checked_at: nil)
    assert @source.quota_stale?

    @source.update!(last_quota_checked_at: 7.hours.ago)
    assert @source.quota_stale?
    assert_not @source.quota_fresh?

    @source.update!(last_quota_checked_at: 5.hours.ago)
    assert @source.quota_fresh?
  end

  test "sync_all_quotas refreshes every source" do
    Source.update_all(last_quota_checked_at: nil)

    Source.sync_all_quotas

    assert Source.all.all? { |source| source.last_quota_checked_at.present? }
  end

  test "quota_usage returns the percentage of the 24-hour quota used" do
    @source.update!(last_quota: { "max_24_hour_send" => 200.0, "sent_last_24_hours" => 7.0 })

    assert_equal 3.5, @source.quota_usage
  end

  test "quota_usage is nil without quota data or a positive max" do
    @source.update!(last_quota: nil)
    assert_nil @source.quota_usage

    @source.update!(last_quota: { "max_24_hour_send" => 0.0, "sent_last_24_hours" => 7.0 })
    assert_nil @source.quota_usage
  end

  test "quota_high? trips at or above 80 percent usage" do
    @source.update!(last_quota: { "max_24_hour_send" => 100.0, "sent_last_24_hours" => 80.0 })
    assert @source.quota_high?

    @source.update!(last_quota: { "max_24_hour_send" => 100.0, "sent_last_24_hours" => 79.9 })
    assert_not @source.quota_high?

    @source.update!(last_quota: nil)
    assert_not @source.quota_high?
  end

  test "complaint breaker stays open under the minimum send volume" do
    wipe_send_domain
    insert_emails(@source, count: 99)
    record_complaint(@source.emails.first)

    assert_not @source.complaint_rate_exceeded?
  end

  test "complaint breaker trips at or above 0.1 percent of 100+ sends" do
    wipe_send_domain
    insert_emails(@source, count: 100)
    record_complaint(@source.emails.first)

    assert @source.complaint_rate_exceeded?
  end

  test "complaint breaker trips at exactly 0.1 percent" do
    wipe_send_domain
    insert_emails(@source, count: 1000)
    record_complaint(@source.emails.first)

    assert @source.complaint_rate_exceeded?
  end

  test "complaint breaker stays open just below 0.1 percent" do
    wipe_send_domain
    insert_emails(@source, count: 2000)
    record_complaint(@source.emails.first)

    assert_not @source.complaint_rate_exceeded?
  end

  test "complaint breaker ignores complaints outside the 30 day window" do
    wipe_send_domain
    insert_emails(@source, count: 100)
    record_complaint(@source.emails.first, occurred_at: 31.days.ago)

    assert_not @source.complaint_rate_exceeded?
  end

  private
    def insert_emails(source, count:)
      now = Time.current
      Email.insert_all(count.times.map do |index|
        { project_id: source.project_id, workspace_id: source.workspace_id, source_id: source.id,
          from: "hello@acme.com", subject: "Bulk #{index}", status: "sent",
          public_id: "em_breaker_#{index}_#{SecureRandom.alphanumeric(8)}",
          created_at: now, updated_at: now }
      end)
    end

    def record_complaint(email, occurred_at: Time.current)
      email.events.create!(event_type: "complaint", occurred_at: occurred_at, payload: {})
    end
end

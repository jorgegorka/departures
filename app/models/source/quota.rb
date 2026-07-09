module Source::Quota
  extend ActiveSupport::Concern

  QUOTA_TTL = 6.hours
  COMPLAINT_BREAKER_WINDOW = 30.days
  COMPLAINT_BREAKER_MINIMUM_SENDS = 100
  COMPLAINT_BREAKER_RATE = 0.1 # percent

  class_methods do
    def sync_all_quotas
      find_each(&:sync_quota)
    end
  end

  def sync_quota
    response = ses_client.get_account
    update!(last_quota_checked_at: Time.current, last_quota: {
      "max_24_hour_send" => response.send_quota&.max_24_hour_send,
      "max_send_rate" => response.send_quota&.max_send_rate,
      "sent_last_24_hours" => response.send_quota&.sent_last_24_hours,
      "sending_enabled" => response.sending_enabled,
      "production_access" => response.production_access_enabled
    })
    true
  rescue Aws::SESV2::Errors::ServiceError
    false
  end

  def quota_stale?
    last_quota_checked_at.nil? || last_quota_checked_at < QUOTA_TTL.ago
  end

  def quota_fresh?
    !quota_stale?
  end

  def complaint_rate_exceeded?
    sends = emails.where(created_at: COMPLAINT_BREAKER_WINDOW.ago..).count

    if sends < COMPLAINT_BREAKER_MINIMUM_SENDS
      false
    else
      complaints = EmailEvent.where(email_id: emails.select(:id), event_type: "complaint",
        occurred_at: COMPLAINT_BREAKER_WINDOW.ago..).distinct.count(:email_id)
      complaints * 100.0 / sends >= COMPLAINT_BREAKER_RATE
    end
  end
end

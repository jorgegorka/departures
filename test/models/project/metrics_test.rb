require "test_helper"

class Project::MetricsTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    @project = projects(:acme_default)
    wipe_send_domain
    Rails.cache.clear # cache keys include max(updated_at) at 1s resolution — two tests creating rows in the same second would otherwise share entries
  end

  test "counts volume from emails and the funnel from distinct event emails" do
    delivered = create_email(created_at: 1.hour.ago)
    opened = create_email(created_at: 2.hours.ago)
    create_email(created_at: 3.hours.ago) # accepted, no events
    record_event(delivered, "delivery", 1.hour.ago)
    record_event(opened, "delivery", 2.hours.ago)
    record_event(opened, "open", 1.hour.ago)
    record_event(opened, "open", 30.minutes.ago) # duplicate open, same email

    metrics = @project.metrics_for("24h")

    assert_equal 3, metrics.sent_count
    assert_equal 2, metrics.delivered_count
    assert_equal 1, metrics.opened_count
    assert_in_delta 66.7, metrics.delivery_rate
    assert_in_delta 50.0, metrics.open_rate
  end

  test "rates guard divide-by-zero" do
    metrics = @project.metrics_for("24h")

    assert_equal 0, metrics.sent_count
    assert_equal 0.0, metrics.delivery_rate
    assert_equal 0.0, metrics.open_rate
  end

  test "deltas compare against the immediately preceding window of equal length" do
    create_email(created_at: 2.hours.ago)
    create_email(created_at: 3.hours.ago)
    create_email(created_at: 30.hours.ago) # previous 24h window

    metrics = @project.metrics_for("24h")

    assert_equal 1, metrics.sent_delta
  end

  test "sparkline zero-fills one bucket per interval" do
    create_email(created_at: 1.hour.ago)

    assert_equal 24, @project.metrics_for("24h").sparkline_values.size
    assert_equal 7, @project.metrics_for("7d").sparkline_values.size
    assert_equal 30, @project.metrics_for("30d").sparkline_values.size
    assert_equal 1, @project.metrics_for("24h").sparkline_values.sum
  end

  test "unknown ranges fall back to 7d" do
    assert_equal "7d", @project.metrics_for("century").range
    assert_equal "7d", @project.metrics_for(nil).range
  end

  test "cache_key changes when email activity lands" do
    before = @project.metrics_for("7d").cache_key
    create_email(created_at: 5.minutes.ago)

    assert_not_equal before, @project.metrics_for("7d").cache_key
  end

  private
    def create_email(created_at:)
      @project.emails.create!(source: sources(:acme_production), from: "hello@acme.com",
        subject: "Metric", text_body: "Body", created_at: created_at)
    end

    def record_event(email, event_type, occurred_at)
      email.events.create!(event_type: event_type, occurred_at: occurred_at)
    end
end

require "test_helper"

class Project::ReportTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    @project = projects(:acme_default)
    wipe_send_domain
    Rails.cache.clear # cache keys include max(updated_at) at 1s resolution — two tests creating rows in the same second would otherwise share entries
  end

  test "defaults to 30d and falls back on unknown ranges" do
    assert_equal "30d", @project.report_for(nil).range
    assert_equal "30d", @project.report_for("century").range
    assert_equal "90d", @project.report_for("90d").range
  end

  test "series zero-fill one bucket per interval for every metric" do
    email = create_email(created_at: 1.hour.ago)
    record_event(email, "delivery", 1.hour.ago)

    series = @project.report_for("7d").series

    assert_equal %i[sent delivered opened clicked bounced complained], series.keys
    series.each_value { |values| assert_equal 7, values.size }
    assert_equal 1, series[:sent].sum
    assert_equal 1, series[:delivered].sum
    assert_equal 0, series[:opened].sum
  end

  test "series count distinct emails per event type" do
    email = create_email(created_at: 2.hours.ago)
    record_event(email, "open", 1.hour.ago)
    record_event(email, "open", 30.minutes.ago) # duplicate open, same email

    assert_equal 1, @project.report_for("24h").series[:opened].sum
  end

  test "series and suppression growth query only the labeled window so leading events keep their bucket" do
    starts_at = Time.current.utc.beginning_of_hour - 23.hours # oldest 24h bucket
    leading = create_email(created_at: starts_at)
    record_event(leading, "delivery", starts_at)
    @project.suppressions.delete_all
    @project.suppressions.create!(email: "edge@example.com", reason: "bounce", created_at: starts_at)
    @project.suppressions.create!(email: "early@example.com", reason: "bounce", created_at: starts_at - 1.minute)

    report = @project.report_for("24h")

    assert_equal 1, report.series[:delivered].sum
    assert_equal 1, report.series[:delivered].first # lands in the leading bucket, not dropped
    assert_equal 1, report.suppression_series.sum # pre-window suppression excluded, not silently dropped
  end

  test "labels match the range buckets" do
    report = @project.report_for("24h")

    assert_equal 24, report.labels.size
    assert_equal 90, @project.report_for("90d").labels.size
  end

  test "bounce aggregates split hard and soft over the range" do
    create_email(created_at: 1.day.ago, status: :bounced, bounce_type: "permanent")
    create_email(created_at: 2.days.ago, status: :bounced, bounce_type: "transient")
    create_email(created_at: 3.days.ago, status: :bounced, bounce_type: "transient")
    create_email(created_at: 4.days.ago) # healthy
    create_email(created_at: 40.days.ago, status: :bounced, bounce_type: "permanent") # outside range

    report = @project.report_for("30d")

    assert_equal 1, report.hard_bounce_count
    assert_equal 2, report.soft_bounce_count
  end

  test "bounce rate uses distinct bounced emails over accepted volume" do
    bounced = create_email(created_at: 1.day.ago)
    create_email(created_at: 2.days.ago)
    record_event(bounced, "bounce", 1.day.ago)

    assert_in_delta 50.0, @project.report_for("7d").bounce_rate
  end

  test "bounce rate is cohort-based: bounces on emails created outside the window don't inflate it" do
    old_email = create_email(created_at: 40.days.ago)
    record_event(old_email, "bounce", 1.hour.ago) # bounce arrives inside the window
    create_email(created_at: 1.day.ago) # healthy in-window email

    report = @project.report_for("30d")

    assert_equal 1, report.accepted_count
    assert_in_delta 0.0, report.bounce_rate # never 100%+ from out-of-cohort emails
  end

  test "suppression growth buckets new suppressions and counts active ones" do
    @project.suppressions.delete_all
    @project.suppressions.create!(email: "one@example.com", reason: "bounce", created_at: 1.day.ago)
    @project.suppressions.create!(email: "two@example.com", reason: "complaint", created_at: 2.days.ago)
    @project.suppressions.create!(email: "old@example.com", reason: "bounce", created_at: 40.days.ago)
    @project.suppressions.create!(email: "lapsed@example.com", reason: "bounce",
      created_at: 1.day.ago, expires_at: 1.hour.ago)

    report = @project.report_for("30d")

    assert_equal 30, report.suppression_series.size
    assert_equal 3, report.suppression_series.sum # lapsed one still counts as added in range
    assert_equal 3, report.active_suppression_count
  end

  test "breakdown by source ranks rows by sent volume" do
    other = @project.sources.create!(name: "Acme staging", environment: "sandbox", region: "eu-west-1",
      aws_access_key_id: "AKIA2", aws_secret_access_key: "secret2")
    2.times { |i| create_email(created_at: (i + 1).hours.ago) }
    staging_email = create_email(created_at: 1.hour.ago, source: other)
    record_event(staging_email, "delivery", 1.hour.ago)

    rows = @project.report_for("7d").breakdown_by_source

    assert_equal [ "Acme production", "Acme staging" ], rows.map { |row| row[:key] }
    assert_equal 2, rows.first[:sent]
    assert_equal 1, rows.second[:delivered]
    assert_equal 0, rows.first[:delivered]
  end

  test "breakdown by domain extracts the domain from bare and display-name froms" do
    plain = create_email(created_at: 1.hour.ago, from: "hello@acme.com")
    create_email(created_at: 2.hours.ago, from: "Acme Billing <billing@mail.acme.com>")
    record_event(plain, "bounce", 1.hour.ago)

    rows = @project.report_for("7d").breakdown_by_domain

    assert_equal %w[ acme.com mail.acme.com ], rows.map { |row| row[:key] }.sort
    acme = rows.find { |row| row[:key] == "acme.com" }
    assert_equal 1, acme[:sent]
    assert_in_delta 100.0, acme[:bounce_rate]
  end

  test "breakdown by tag unnests json tag pairs and skips untagged emails" do
    welcome = create_email(created_at: 1.hour.ago, tags: { "campaign" => "welcome", "tier" => "pro" })
    create_email(created_at: 2.hours.ago, tags: { "campaign" => "welcome" })
    create_email(created_at: 3.hours.ago) # untagged
    record_event(welcome, "click", 1.hour.ago)

    rows = @project.report_for("7d").breakdown_by_tag

    assert_equal [ "campaign=welcome", "tier=pro" ], rows.map { |row| row[:key] }
    assert_equal 2, rows.first[:sent]
    assert_equal 1, rows.first[:clicked]
  end

  test "empty project produces zeroed report without divide-by-zero" do
    report = @project.report_for("7d")

    assert_equal 0, report.bounce_rate
    assert_equal 0, report.hard_bounce_count
    assert_empty report.breakdown_by_source
    assert_empty report.breakdown_by_tag
  end

  test "bounce tiles are computed without evaluating the series and breakdown section" do
    create_email(created_at: 1.day.ago, status: :bounced, bounce_type: "permanent")

    report = @project.report_for("30d")
    report.hard_bounce_count
    report.soft_bounce_count
    report.bounce_rate

    assert_nil report.instance_variable_get(:@computed) # heavy section untouched
    assert_not_nil report.instance_variable_get(:@bounce_summary)
  end

  test "cache_key changes when suppressions change" do
    @project.suppressions.delete_all
    before = @project.report_for("7d").cache_key
    @project.suppressions.create!(email: "new@example.com", reason: "bounce")

    assert_not_equal before, @project.report_for("7d").cache_key
  end

  private
    def create_email(created_at:, from: "hello@acme.com", source: sources(:acme_production),
      status: :queued, bounce_type: nil, tags: {})
      @project.emails.create!(source: source, from: from, subject: "Report", text_body: "Body",
        created_at: created_at, status: status, bounce_type: bounce_type, tags: tags)
    end

    def record_event(email, event_type, occurred_at)
      email.events.create!(event_type: event_type, occurred_at: occurred_at)
    end
end

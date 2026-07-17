require "test_helper"

class Project::TimeBucketsTest < ActiveSupport::TestCase
  test "hourly buckets for 24h" do
    buckets = Project::TimeBuckets.new(range: "24h", window: 24.hours)

    assert_equal "%Y-%m-%dT%H", buckets.format
    assert_equal 24, buckets.labels.size
    assert_equal Time.current.utc.beginning_of_hour.strftime("%Y-%m-%dT%H"), buckets.labels.last
  end

  test "daily buckets for day ranges" do
    assert_equal 7, Project::TimeBuckets.new(range: "7d", window: 7.days).labels.size
    assert_equal 30, Project::TimeBuckets.new(range: "30d", window: 30.days).labels.size
    assert_equal 90, Project::TimeBuckets.new(range: "90d", window: 90.days).labels.size
    assert_equal "%Y-%m-%d", Project::TimeBuckets.new(range: "7d", window: 7.days).format
  end

  test "labels are consecutive and end today in UTC" do
    labels = Project::TimeBuckets.new(range: "7d", window: 7.days).labels

    assert_equal Time.current.utc.beginning_of_day.strftime("%Y-%m-%d"), labels.last
    assert_equal (Time.current.utc.beginning_of_day - 6.days).strftime("%Y-%m-%d"), labels.first
  end

  test "starts_at is the oldest label's bucket start" do
    hourly = Project::TimeBuckets.new(range: "24h", window: 24.hours)
    daily = Project::TimeBuckets.new(range: "7d", window: 7.days)

    assert_equal Time.current.utc.beginning_of_hour - 23.hours, hourly.starts_at
    assert_equal hourly.labels.first, hourly.starts_at.strftime(hourly.format)
    assert_equal Time.current.utc.beginning_of_day - 6.days, daily.starts_at
    assert_equal daily.labels.first, daily.starts_at.strftime(daily.format)
  end

  test "fill aligns counts to labels and zero-fills gaps" do
    buckets = Project::TimeBuckets.new(range: "7d", window: 7.days)
    today = Time.current.utc.strftime("%Y-%m-%d")

    filled = buckets.fill({ today => 3 })

    assert_equal 7, filled.size
    assert_equal 3, filled.last
    assert_equal 3, filled.sum
  end
end

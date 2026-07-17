class Project::Metrics < Project::RangedReport
  DEFAULT_RANGE = "7d"
  # Don't cry wolf on tiny cohorts (1 send + 1 bounce is 100%): reuse the SES
  # breaker's minimum before rate warnings can fire.
  WARNING_MINIMUM_VOLUME = Source::Quota::COMPLAINT_BREAKER_MINIMUM_SENDS

  def sent_count
    current.fetch(:accepted)
  end

  def complaint_count
    current.fetch(:complained)
  end

  def delivery_rate
    rate(current[:delivered], current[:accepted])
  end

  def open_rate
    rate(current[:opened], current[:delivered])
  end

  def click_rate
    rate(current[:clicked], current[:delivered])
  end

  def bounce_rate
    rate(current[:bounced], current[:accepted])
  end

  def sent_delta
    current[:accepted] - previous[:accepted]
  end

  def delivery_rate_delta
    delivery_rate - rate(previous[:delivered], previous[:accepted])
  end

  def open_rate_delta
    open_rate - rate(previous[:opened], previous[:delivered])
  end

  def click_rate_delta
    click_rate - rate(previous[:clicked], previous[:delivered])
  end

  def bounce_rate_delta
    bounce_rate - rate(previous[:bounced], previous[:accepted])
  end

  def complaint_delta
    current[:complained] - previous[:complained]
  end

  def sparkline_values
    computed.fetch(:sparkline)
  end

  def sparkline_points(width: 120, height: 32)
    values = sparkline_values
    peak = [ values.max.to_i, 1 ].max
    step = width.to_f / [ values.size - 1, 1 ].max

    values.each_with_index.map do |value, index|
      "#{(index * step).round(1)},#{(height - (value * height.to_f / peak)).round(1)}"
    end.join(" ")
  end

  def event_series
    computed.fetch(:event_series)
  end

  # Plain-language deliverability flags for the dashboard warning strip.
  # Empty when sending is healthy — the strip only renders on real anomalies.
  def warnings
    @warnings ||= [ bounce_warning, complaint_warning ].compact + source_warnings
  end

  def cache_key
    @cache_key ||= [ "project-metrics", *cache_key_segments ].join("/")
  end

  private
    def current
      computed.fetch(:current)
    end

    def previous
      computed.fetch(:previous)
    end

    def computed
      @computed ||= Rails.cache.fetch(cache_key, expires_in: 60.seconds) do
        { current: cohort_totals(period), previous: cohort_totals(previous_period),
          sparkline: zero_filled_buckets, event_series: funnel_series.slice(:delivered, :bounced) }
      end
    end

    # The window of equal length immediately preceding the current one,
    # exclusive of the boundary so no email lands in both cohorts.
    def previous_period
      (buckets.starts_at - window)...buckets.starts_at
    end

    def zero_filled_buckets
      counts = emails_in_period.group(Arel.sql("strftime('#{buckets.format}', created_at)")).count

      buckets.fill(counts)
    end

    def bounce_warning
      return if current[:accepted] < WARNING_MINIMUM_VOLUME

      if bounce_rate >= BOUNCE_ALERT_RATE
        "Bounce rate is #{bounce_rate}% — above the #{BOUNCE_ALERT_RATE.round}% alert threshold. Check the bounces page."
      end
    end

    def complaint_warning
      return if current[:accepted] < WARNING_MINIMUM_VOLUME

      complaint_rate = rate(current[:complained], current[:accepted])
      if complaint_rate >= Source::Quota::COMPLAINT_BREAKER_RATE
        "Complaint rate is #{complaint_rate}% — SES pauses sending at #{Source::Quota::COMPLAINT_BREAKER_RATE}%."
      end
    end

    def source_warnings
      project.sources.flat_map do |source|
        [ (%(SES has paused sending for "#{source.name}".) if (source.last_quota || {})["sending_enabled"] == false),
          ("\"#{source.name}\" has used #{source.quota_usage.round}% of its 24-hour SES quota." if source.quota_high?),
          # A never-synced source hasn't gone stale — quota_stale? is also true
          # for nil last_quota_checked_at because EmailSubmission uses it to
          # force a first sync, but that's not a dashboard anomaly.
          (%(Quota data for "#{source.name}" is stale — last checked #{ActionController::Base.helpers.time_ago_in_words(source.last_quota_checked_at)} ago.) if source.last_quota_checked_at && source.quota_stale?) ].compact
      end
    end
end

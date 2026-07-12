class Project::Metrics
  RANGES = TimeRangeFilterable::TIME_RANGES.slice("24h", "7d", "30d").freeze
  DEFAULT_RANGE = "7d"
  EVENT_COUNTERS = { delivered: "delivery", opened: "open", clicked: "click",
    bounced: "bounce", complained: "complaint" }.freeze

  attr_reader :project, :range

  def initialize(project, range: DEFAULT_RANGE)
    @project = project
    @range = RANGES.key?(range.to_s) ? range.to_s : DEFAULT_RANGE
  end

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

  def cache_key
    @cache_key ||= [ "project-metrics", project.id, range, project.emails.maximum(:updated_at)&.to_i ].join("/")
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
        { current: totals_in(current_period), previous: totals_in(previous_period),
          sparkline: zero_filled_buckets }
      end
    end

    def current_period
      window.ago..Time.current
    end

    def previous_period
      (window * 2).ago..window.ago
    end

    def window
      RANGES.fetch(range)
    end

    def totals_in(period)
      event_counts = EmailEvent.where(email_id: project.emails.select(:id), occurred_at: period)
        .group(:event_type).distinct.count(:email_id)

      EVENT_COUNTERS.transform_values { |event_type| event_counts.fetch(event_type, 0) }
        .merge(accepted: project.emails.where(created_at: period).count)
    end

    def zero_filled_buckets
      counts = project.emails.where(created_at: current_period)
        .group(Arel.sql("strftime('#{bucket_format}', created_at)")).count

      bucket_labels.map { |label| counts.fetch(label, 0) }
    end

    def bucket_format
      range == "24h" ? "%Y-%m-%dT%H" : "%Y-%m-%d"
    end

    # created_at is stored UTC, so bucket labels are computed in UTC to match
    # what SQLite's strftime sees.
    def bucket_labels
      step = range == "24h" ? 1.hour : 1.day
      count = (window / step).to_i
      newest = range == "24h" ? Time.current.utc.beginning_of_hour : Time.current.utc.beginning_of_day

      (0...count).map { |index| (newest - (count - 1 - index) * step).strftime(bucket_format) }
    end

    def rate(numerator, denominator)
      if denominator.zero?
        0.0
      else
        (numerator * 100.0 / denominator).round(1)
      end
    end
end

# Shared plumbing for range-scoped project analytics (Project::Metrics,
# Project::Report): range normalization, time bucketing, the distinct-email
# funnel series, and shared alert thresholds. Subclasses define DEFAULT_RANGE.
class Project::RangedReport
  RANGES = TimeRangeFilterable::TIME_RANGES.slice("24h", "7d", "30d", "90d").freeze
  FUNNEL_EVENTS = { delivered: "delivery", opened: "open", clicked: "click",
    bounced: "bounce", complained: "complaint" }.freeze
  BOUNCE_ALERT_RATE = 5.0 # percent — above this a segment gets the attention treatment

  attr_reader :project, :range

  def initialize(project, range: self.class::DEFAULT_RANGE)
    @project = project
    @range = RANGES.key?(range.to_s) ? range.to_s : self.class::DEFAULT_RANGE
  end

  def labels
    buckets.labels
  end

  private
    # Aligned with the labeled buckets (not a raw `window.ago..now`), so every
    # row a bucketed series queries lands on a label instead of being dropped
    # by TimeBuckets#fill.
    def period
      buckets.starts_at..Time.current
    end

    def window
      RANGES.fetch(range)
    end

    def buckets
      @buckets ||= Project::TimeBuckets.new(range: range, window: window)
    end

    def emails_in_period(within = period)
      project.emails.where(created_at: within)
    end

    def events_in_period(within = period)
      EmailEvent.where(email_id: project.emails.select(:id), occurred_at: within)
    end

    # Cohort funnel for tiles and rates: distinct emails CREATED in the window
    # that have each event type (whenever the event occurred), plus the cohort
    # size as :accepted. Numerator and denominator share the same cohort, so
    # rates over :accepted can never exceed 100% and can't be zeroed out by a
    # window with events but no new sends.
    def cohort_totals(within = period)
      cohort = emails_in_period(within)
      event_counts = EmailEvent.where(email_id: cohort.select(:id))
        .group(:event_type).distinct.count(:email_id)

      FUNNEL_EVENTS.transform_values { |event_type| event_counts.fetch(event_type, 0) }
        .merge(accepted: cohort.count)
    end

    # Chart series: buckets each email's first occurrence per event type by
    # occurred_at (the right basis for a timeline). Note this differs from the
    # cohort-based tile counts (#cohort_totals) — an event occurring in this
    # window on an email created outside it shows up here but not in the tiles,
    # so series sums and tiles are not expected to match.
    def funnel_series
      counts = Hash.new(0)
      events_in_period.group(:event_type, :email_id).minimum(:occurred_at)
        .each { |(type, _email_id), occurred_at| counts[[ type, occurred_at.utc.strftime(buckets.format) ]] += 1 }

      sent = buckets.fill(emails_in_period.group(Arel.sql("strftime('#{buckets.format}', created_at)")).count)

      { sent: sent }.merge(FUNNEL_EVENTS.transform_values do |event_type|
        buckets.fill(counts.filter_map { |(type, bucket), count| [ bucket, count ] if type == event_type }.to_h)
      end)
    end

    # sources.updated_at covers quota syncs too (sync_quota touches the row),
    # so both caches invalidate on any email or source change in one place.
    def cache_key_segments
      [ project.id, range, project.emails.maximum(:updated_at)&.to_i,
        project.sources.maximum(:updated_at)&.to_i ]
    end

    def rate(numerator, denominator)
      if denominator.zero?
        0.0
      else
        (numerator * 100.0 / denominator).round(1)
      end
    end
end

class Project::Report < Project::RangedReport
  DEFAULT_RANGE = "30d"
  BREAKDOWN_LIMIT = 20
  # Extracts the domain from either "a@b.com" or "Name <a@b.com>".
  DOMAIN_SQL = %(rtrim(substr(emails."from", instr(emails."from", '@') + 1), '>')).freeze
  TAG_SQL = "json_each.key || '=' || json_each.value".freeze

  def series
    computed.fetch(:series)
  end

  def accepted_count
    bounce_summary.fetch(:accepted)
  end

  def hard_bounce_count
    bounce_summary.fetch(:hard_bounces)
  end

  def soft_bounce_count
    bounce_summary.fetch(:soft_bounces)
  end

  def bounce_rate
    rate(bounce_summary.fetch(:bounced), accepted_count)
  end

  def suppression_series
    computed.fetch(:suppression_series)
  end

  def active_suppression_count
    computed.fetch(:active_suppressions)
  end

  def breakdown_by_source
    computed.fetch(:by_source)
  end

  def breakdown_by_domain
    computed.fetch(:by_domain)
  end

  def breakdown_by_tag
    computed.fetch(:by_tag)
  end

  def sources
    project.sources.order(:name)
  end

  def cache_key
    @cache_key ||= [ "project-report", *cache_key_segments,
      project.suppressions.maximum(:updated_at)&.to_i ].join("/")
  end

  private
    # Cheap section on its own cache entry: the bounces page reads only these
    # three tiles, so it never pays for the series and breakdown queries below.
    def bounce_summary
      @bounce_summary ||= Rails.cache.fetch(bounce_summary_cache_key, expires_in: 60.seconds) do
        totals = cohort_totals

        { accepted: totals.fetch(:accepted), bounced: totals.fetch(:bounced),
          hard_bounces: emails_in_period.hard_bounced.count,
          soft_bounces: emails_in_period.soft_bounced.count }
      end
    end

    def bounce_summary_cache_key
      [ "project-report-bounces", *cache_key_segments ].join("/")
    end

    def computed
      @computed ||= Rails.cache.fetch(cache_key, expires_in: 60.seconds) do
        { series: funnel_series,
          suppression_series: suppression_growth,
          active_suppressions: project.suppressions.active.count,
          by_source: source_breakdown, by_domain: domain_breakdown, by_tag: tag_breakdown }
      end
    end

    def suppression_growth
      buckets.fill(project.suppressions.where(created_at: period)
        .group(Arel.sql("strftime('#{buckets.format}', created_at)")).count)
    end

    def source_breakdown
      names = project.sources.pluck(:id, :name).to_h
      breakdown(emails_in_period.group(:source_id).count,
        grouped_events("emails.source_id")) { |source_id| names[source_id] }
    end

    def domain_breakdown
      breakdown(emails_in_period.group(Arel.sql(DOMAIN_SQL)).count, grouped_events(DOMAIN_SQL))
    end

    def tag_breakdown
      volumes = emails_in_period.joins("JOIN json_each(emails.tags)")
        .group(Arel.sql(TAG_SQL)).count
      funnel = events_in_period.joins(:email).joins("JOIN json_each(emails.tags)")
        .group(Arel.sql(TAG_SQL), :event_type).distinct.count(:email_id)

      breakdown(volumes, funnel)
    end

    def grouped_events(expression)
      events_in_period.joins(:email).group(Arel.sql(expression), :event_type).distinct.count(:email_id)
    end

    # volumes: { key => sent }; funnel: { [key, event_type] => count }.
    def breakdown(volumes, funnel)
      volumes.map do |key, sent|
        events = funnel.filter_map { |(k, type), count| [ type, count ] if k == key }.to_h
        bounced = events.fetch("bounce", 0)

        { key: block_given? ? yield(key) : key, sent: sent,
          delivered: events.fetch("delivery", 0), opened: events.fetch("open", 0),
          clicked: events.fetch("click", 0), bounce_rate: rate(bounced, sent) }
      end.sort_by { |row| -row[:sent] }.first(BREAKDOWN_LIMIT)
    end
end

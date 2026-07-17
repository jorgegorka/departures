module ApplicationHelper
  METRIC_RANGE_OPTIONS = { "Last 24 hours" => "24h", "Last 7 days" => "7d",
    "Last 30 days" => "30d", "Last 90 days" => "90d" }.freeze

  def metric_range_options(selected)
    options_for_select(METRIC_RANGE_OPTIONS, selected)
  end

  def metric_range_caption(range)
    METRIC_RANGE_OPTIONS.key(range).to_s.downcase
  end

  # Turns Project::TimeBuckets labels ("2026-07-16T09" / "2026-07-16") into
  # short human labels for chart axes.
  def chart_display_labels(labels, range)
    if range == "24h"
      labels.map { |label| "#{label.last(2)}:00" }
    else
      labels.map { |label| Date.parse(label).strftime("%b %-d") }
    end
  end
end

class Project::TimeBuckets
  attr_reader :range, :window

  def initialize(range:, window:)
    @range = range
    @window = window
  end

  def format
    range == "24h" ? "%Y-%m-%dT%H" : "%Y-%m-%d"
  end

  # created_at is stored UTC, so bucket labels are computed in UTC to match
  # what SQLite's strftime sees.
  def labels
    @labels ||= (0...count).map { |index| (starts_at + index * step).strftime(format) }
  end

  # The oldest label's bucket start. Queries feeding #fill must not reach
  # further back than this, or rows would bucket to a label that doesn't
  # exist and be silently dropped.
  def starts_at
    @starts_at ||= newest - (count - 1) * step
  end

  def fill(counts)
    labels.map { |label| counts.fetch(label, 0) }
  end

  private
    def step
      range == "24h" ? 1.hour : 1.day
    end

    def count
      (window / step).to_i
    end

    def newest
      range == "24h" ? Time.current.utc.beginning_of_hour : Time.current.utc.beginning_of_day
    end
end

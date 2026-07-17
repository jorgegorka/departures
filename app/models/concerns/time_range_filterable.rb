module TimeRangeFilterable
  extend ActiveSupport::Concern

  TIME_RANGES = { "1h" => 1.hour, "24h" => 24.hours, "7d" => 7.days, "30d" => 30.days, "90d" => 90.days }.freeze

  included do
    scope :in_time_range, ->(param) do
      if (window = TIME_RANGES[param])
        where(created_at: window.ago..)
      else
        all
      end
    end
  end
end

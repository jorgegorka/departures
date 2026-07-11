class Session < ApplicationRecord
  belongs_to :user

  scope :by_recent_activity, -> { order(Arel.sql("COALESCE(last_active_at, created_at) DESC"), id: :desc) }

  BROWSERS = { "Edg" => "Edge", "OPR" => "Opera", "Firefox" => "Firefox", "Chrome" => "Chrome", "Safari" => "Safari" }.freeze
  PLATFORMS = { "iPhone" => "iOS", "iPad" => "iPadOS", "Android" => "Android", "Windows" => "Windows",
    "Macintosh" => "macOS", "Mac OS X" => "macOS", "Linux" => "Linux" }.freeze

  def touch_activity
    if last_active_at.nil? || last_active_at < 1.minute.ago
      update_column(:last_active_at, Time.current)
    end
  end

  def current?
    self == Current.session
  end

  def device_summary
    if user_agent.blank?
      "Unknown device"
    else
      browser = BROWSERS.find { |token, _| user_agent.include?(token) }&.last
      platform = PLATFORMS.find { |token, _| user_agent.include?(token) }&.last
      [ browser, platform ].compact.join(" on ").presence || user_agent.truncate(40)
    end
  end
end

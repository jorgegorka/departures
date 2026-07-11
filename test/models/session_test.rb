require "test_helper"

class SessionTest < ActiveSupport::TestCase
  test "touch_activity stamps at most once per minute" do
    session = sessions(:owner)

    session.touch_activity
    first = session.reload.last_active_at
    assert first.present?

    session.touch_activity
    assert_equal first, session.reload.last_active_at

    session.update_column(:last_active_at, 2.minutes.ago)
    session.touch_activity
    assert session.reload.last_active_at > first - 1.minute
  end

  test "device_summary names browser and platform" do
    session = Session.new(user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36")
    assert_equal "Chrome on macOS", session.device_summary

    assert_equal "Unknown device", Session.new(user_agent: nil).device_summary
  end
end

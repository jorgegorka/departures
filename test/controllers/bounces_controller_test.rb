require "test_helper"

class BouncesControllerTest < ActionDispatch::IntegrationTest
  test "index defaults to all bounces and splits hard and soft" do
    sign_in_as users(:owner)
    get bounces_url

    assert_response :success
    assert_select "body", text: /Password reset/
    assert_select "body", text: /Mailbox full retry/

    get bounces_url(filter: "hard_bounces")
    assert_select "body", text: /Password reset/
    assert_select "body", { text: /Mailbox full retry/, count: 0 }

    get bounces_url(filter: "soft_bounces")
    assert_select "body", text: /Mailbox full retry/
    assert_select "body", { text: /Password reset/, count: 0 }
  end

  test "index shows a 30-day bounce summary" do
    sign_in_as users(:owner)
    get bounces_url

    assert_response :success
    assert_select ".report-stats .chart-grid__title", text: "Hard bounces"
    assert_select ".report-stats .chart-grid__title", text: "Soft bounces"
    assert_select ".report-stats .chart-grid__title", text: "Bounce rate"
  end
end

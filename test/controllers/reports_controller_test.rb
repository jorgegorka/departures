require "test_helper"

class ReportsControllerTest < ActionDispatch::IntegrationTest
  test "requires authentication" do
    get report_url

    assert_redirected_to new_session_url
  end

  test "renders the report for the current project" do
    sign_in_as users(:owner)

    get report_url

    assert_response :success
    assert_select ".chart-grid figure", 6
    assert_select "script[type='application/json']"
    assert_select "table", minimum: 1
  end

  test "defaults to 30 days and falls back on unknown ranges" do
    sign_in_as users(:owner)

    get report_url(range: "century")

    assert_response :success
    assert_select "option[value=?][selected]", "30d"
  end

  test "range param drives the report window" do
    sign_in_as users(:owner)

    get report_url(range: "90d")

    assert_response :success
    assert_select "option[value=?][selected]", "90d"
  end

  test "only reports on the current workspace's project" do
    sign_in_as users(:owner)

    get report_url

    assert_response :success
    assert_select "[data-project-slug=?]", projects(:acme_default).slug
  end
end

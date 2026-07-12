require "test_helper"

class DashboardsControllerTest < ActionDispatch::IntegrationTest
  test "requires authentication" do
    get root_url

    assert_redirected_to new_session_url
  end

  test "defaults to the user's first workspace and active project" do
    sign_in_as users(:owner)

    get root_url

    assert_response :success
    assert_select "[data-workspace-slug=?]", "acme"
  end

  test "shows metric tiles for the current project" do
    sign_in_as users(:owner)
    get root_url

    assert_response :success
    assert_select ".board__metric", 6
    assert_select ".sparkline svg polyline"
  end

  test "range param drives the metrics window" do
    sign_in_as users(:owner)
    get root_url(range: "24h")

    assert_response :success
    assert_select "option[value=?][selected]", "24h"
  end
end

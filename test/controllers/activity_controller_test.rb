require "test_helper"

class ActivityControllerTest < ActionDispatch::IntegrationTest
  test "requires authentication" do
    get activity_url

    assert_redirected_to new_session_url
  end

  test "lists the current project's latest emails with a live stream subscription" do
    sign_in_as users(:owner)
    get activity_url

    assert_response :success
    assert_select "turbo-cable-stream-source", 1
    assert_select ".activity__row", { minimum: 5 }
    assert_select "body", text: /April invoice/
    assert_select "body", { text: /Globex says hi/, count: 0 }
  end

  test "filter and range params narrow the feed" do
    sign_in_as users(:owner)
    get activity_url(filter: "bounced")

    assert_select "body", text: /Password reset/
    assert_select "body", { text: /April invoice/, count: 0 }

    get activity_url(range: "1h")

    assert_select "body", text: /April invoice/
    assert_select "body", { text: /Welcome aboard/, count: 0 }
  end

  test "search narrows by recipient" do
    sign_in_as users(:owner)
    get activity_url(q: "searchme@customer")

    assert_select "body", text: /Welcome aboard/
    assert_select "body", { text: /April invoice/, count: 0 }
  end
end

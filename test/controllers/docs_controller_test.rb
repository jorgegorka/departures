require "test_helper"

class DocsControllerTest < ActionDispatch::IntegrationTest
  test "index renders for an anonymous visitor" do
    get docs_path

    assert_response :success
    assert_select "h1", text: "Documentation"
  end

  test "every registered page renders for an anonymous visitor" do
    Docs::Page.all.each do |page|
      get doc_path(page.slug)

      assert_response :success, "Docs page #{page.slug} did not render"
      assert_select "h1"
    end
  end

  test "an unknown slug responds with 404" do
    get doc_path("bogus")

    assert_response :not_found
  end

  test "a signed-in user with an unonboarded workspace is not redirected away" do
    workspaces(:acme).update!(onboarded_at: nil)
    sign_in_as users(:owner)

    get docs_path

    assert_response :success
  end
end

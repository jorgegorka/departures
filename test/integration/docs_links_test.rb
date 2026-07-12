require "test_helper"

class DocsLinksTest < ActionDispatch::IntegrationTest
  test "every internal docs link on every docs page resolves to a registered page" do
    paths = [ docs_path ] + Docs::Page.all.map { |page| doc_path(page) }

    paths.each do |path|
      get path

      assert_response :success
      css_select("a[href^='/docs']").each do |anchor|
        href = anchor["href"].split("#").first
        next if href == docs_path
        slug = href.delete_prefix("/docs/")

        assert Docs::Page.all.any? { |page| page.slug == slug },
          "#{path} links to unregistered docs page #{href}"
      end
    end
  end
end

require "test_helper"

class DocsHelperTest < ActionView::TestCase
  test "docs_link_to links to the registered page" do
    html = docs_link_to("Learn more", "getting-started")

    assert_includes html, doc_path("getting-started")
    assert_includes html, "Learn more"
  end

  test "docs_link_to raises for an unregistered slug" do
    assert_raises(ActiveRecord::RecordNotFound) { docs_link_to("Learn more", "nope") }
  end
end

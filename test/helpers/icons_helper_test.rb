require "test_helper"

class IconsHelperTest < ActionView::TestCase
  test "icon_tag renders a masked, aria-hidden span with a per-icon class" do
    html = icon_tag("check")

    assert_match(/class="icon icon--check"/, html)
    assert_match(/aria-hidden="true"/, html)
    assert_no_match(/style=/, html)
  end

  test "icon_tag merges extra classes" do
    assert_match(/class="icon icon--check txt-subtle"/, icon_tag("check", class: "txt-subtle"))
  end
end

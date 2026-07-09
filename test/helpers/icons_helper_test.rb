require "test_helper"

class IconsHelperTest < ActionView::TestCase
  test "icon_tag renders a masked, aria-hidden span" do
    html = icon_tag("check")

    assert_match(/class="icon"/, html)
    assert_match(/aria-hidden="true"/, html)
    assert_match(/--svg: url\(.*check.*\.svg\)/, html)
  end

  test "icon_tag merges extra classes" do
    assert_match(/class="icon txt-subtle"/, icon_tag("check", class: "txt-subtle"))
  end
end

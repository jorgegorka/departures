require "test_helper"

class TemplateTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "workspace defaults from the project and slug is unique per project" do
    template = projects(:acme_default).templates.create!(name: "Reset", slug: "reset", text_body: "Hi")
    assert_equal workspaces(:acme), template.workspace

    duplicate = projects(:acme_default).templates.build(name: "Reset 2", slug: "reset", text_body: "Hi")
    assert_not duplicate.valid?

    other_project = projects(:globex_default).templates.build(name: "Reset", slug: "reset", text_body: "Hi")
    assert other_project.valid?
  end

  test "slug is normalized and constrained" do
    template = projects(:acme_default).templates.create!(name: "X", slug: "  My-Slug ", text_body: "Hi")
    assert_equal "my-slug", template.slug

    assert_not projects(:acme_default).templates.build(name: "X", slug: "no spaces", text_body: "Hi").valid?
  end

  test "a body is required" do
    assert_not projects(:acme_default).templates.build(name: "X", slug: "x").valid?
    assert projects(:acme_default).templates.build(name: "X", slug: "x", html_body: "<p>Hi</p>").valid?
  end

  test "render substitutes variables across subject, html, and text" do
    rendered = templates(:acme_welcome).render({ "name" => "Ada", "company" => "Acme" })

    assert_equal "Welcome, Ada!", rendered.subject
    assert_equal "<h1>Hi Ada</h1><p>Thanks for joining Acme.</p>", rendered.html
    assert_equal "Hi Ada — thanks for joining Acme.", rendered.text
  end

  test "render escapes HTML in the html body only" do
    rendered = templates(:acme_welcome).render({ "name" => "<script>alert(1)</script>", "company" => "A&B" })

    assert_includes rendered.html, "&lt;script&gt;"
    assert_includes rendered.html, "A&amp;B"
    assert_includes rendered.text, "A&B"
    assert_includes rendered.subject, "<script>"
  end

  test "render blanks missing variables and tolerates whitespace in tags" do
    template = projects(:acme_default).templates.create!(name: "Spacey", slug: "spacey",
      text_body: "Hello {{  name  }}, welcome to {{ company }}")

    assert_equal "Hello Ada, welcome to ", template.render({ "name" => "Ada" }).text
  end
end

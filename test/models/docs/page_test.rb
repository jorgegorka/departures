require "test_helper"

class Docs::PageTest < ActiveSupport::TestCase
  test "find returns the entry for a registered slug" do
    page = Docs::Page.find("getting-started")

    assert_equal "Getting started", page.title
    assert_equal "getting_started", page.partial
  end

  test "find raises RecordNotFound for an unknown slug" do
    assert_raises(ActiveRecord::RecordNotFound) { Docs::Page.find("bogus") }
  end

  test "every registered page has a template on disk" do
    Docs::Page.all.each do |page|
      path = Rails.root.join("app/views/docs/pages/_#{page.partial}.html.erb")

      assert path.exist?, "Missing template for docs page #{page.slug}: #{path}"
    end
  end

  test "every registered page belongs to a known section" do
    Docs::Page.all.each do |page|
      assert_includes Docs::Page::SECTIONS, page.section
    end
  end
end

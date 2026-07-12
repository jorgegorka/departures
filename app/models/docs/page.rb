class Docs::Page
  Entry = Data.define(:slug, :title, :section) do
    def partial = slug.tr("-", "_")
    def to_param = slug
  end

  SECTIONS = [
    "Getting started",
    "Dashboard guides",
    "API reference",
    "Webhooks",
    "Self-hosting & operations"
  ].freeze

  PAGES = [
    Entry.new(slug: "getting-started", title: "Getting started", section: "Getting started")
  ].freeze

  class << self
    def all
      PAGES
    end

    def find(slug)
      PAGES.find { |page| page.slug == slug } ||
        raise(ActiveRecord::RecordNotFound.new("Couldn't find docs page #{slug.inspect}", "Docs::Page", :slug, slug))
    end

    def sections
      SECTIONS.index_with { |section| PAGES.select { |page| page.section == section } }
    end
  end
end

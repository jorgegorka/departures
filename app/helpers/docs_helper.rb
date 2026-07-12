module DocsHelper
  def docs_link_to(text, slug, **options)
    link_to text, doc_path(Docs::Page.find(slug)), **options
  end
end

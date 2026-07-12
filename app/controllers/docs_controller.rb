class DocsController < ApplicationController
  allow_unauthenticated_access
  allow_unonboarded_access
  allow_two_factor_unenrolled_access

  layout "docs"

  def index
  end

  def show
    @page = Docs::Page.find(params[:slug])
  end
end

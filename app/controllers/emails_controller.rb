class EmailsController < ApplicationController
  PREVIEW_CSP = "default-src 'none'; img-src * data:; style-src 'unsafe-inline'".freeze

  include EmailScoped
  skip_before_action :set_email, only: :index

  def index
    if Current.project
      @emails = Current.project.emails.indexed_by(params[:filter]).sorted_by(params[:sort])
        .in_time_range(params[:range]).search(params[:q]).preloaded.limit(100)
    end
  end

  def show
  end

  # Customer HTML renders inside a sandboxed iframe: scripts/frames/fetches are
  # blocked by the CSP; remote + data images and inline styles stay allowed
  # because marketing mail depends on them.
  def preview
    response.headers["Content-Security-Policy"] = PREVIEW_CSP
    response.headers["X-Frame-Options"] = "SAMEORIGIN"

    if @email.html_body.present?
      render html: @email.html_body.html_safe, layout: false
    else
      render plain: @email.text_body.to_s
    end
  end

  def raw
    if @email.mime_path.present?
      send_file Email::MimeStore.root.join(@email.mime_path), type: "message/rfc822",
        filename: "#{@email.public_id}.eml", disposition: "attachment"
    else
      head :not_found
    end
  end
end

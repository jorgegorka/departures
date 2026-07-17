class BouncesController < ApplicationController
  def index
    if Current.project
      @emails = Current.project.emails.indexed_by(params[:filter].presence || "bounced")
        .reverse_chronologically.preloaded.limit(100)
      @report = Current.project.report_for("30d")
    end
  end
end

class Sources::QuotaSyncsController < ApplicationController
  include RequiresProject

  before_action -> { authorize_capability! :manage_domains }

  def create
    source = Current.project.sources.find(params[:source_id])

    if source.sync_quota
      redirect_to sources_path, notice: "Quota refreshed."
    else
      redirect_to sources_path, alert: "Could not reach SES to refresh the quota."
    end
  end
end

class DashboardsController < ApplicationController
  def show
    if Current.project
      @metrics = Current.project.metrics_for(params[:range])
    end
  end
end

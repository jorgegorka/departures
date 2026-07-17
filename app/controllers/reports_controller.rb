class ReportsController < ApplicationController
  def show
    if Current.project
      @report = Current.project.report_for(params[:range])
    end
  end
end

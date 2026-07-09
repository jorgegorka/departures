class ActivityController < ApplicationController
  def show
    if Current.project
      @emails = Current.project.emails.indexed_by(params[:filter]).in_time_range(params[:range])
        .search(params[:q]).reverse_chronologically.preloaded.limit(50)
    end
  end
end

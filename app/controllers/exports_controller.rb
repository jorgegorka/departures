class ExportsController < ApplicationController
  def show
    if csv = csv_for(params[:id])
      send_data csv, filename: "#{params[:id]}-#{Date.current.iso8601}.csv", type: "text/csv"
    else
      head :not_found
    end
  end

  private
    def csv_for(kind)
      case kind
      when "emails" then Current.project.emails.to_csv
      when "bounces" then Current.project.emails.bounced.to_csv
      when "suppressions" then Current.project.suppressions.to_csv
      end
    end
end

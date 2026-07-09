class SuppressionsController < ApplicationController
  include RequiresProject

  skip_before_action :require_project, only: :index
  before_action -> { authorize_capability! :send }, only: %i[ create destroy ]

  def index
    if Current.project
      @suppressions = Current.project.suppressions.order(created_at: :desc)
    end
  end

  def create
    Suppression.record(Current.project, suppression_params[:email], reason: "manual")
    redirect_to suppressions_path, notice: "Address suppressed."
  rescue ActiveRecord::RecordInvalid => invalid
    redirect_to suppressions_path, alert: invalid.record.errors.full_messages.to_sentence
  end

  def destroy
    Current.project.suppressions.find(params[:id]).destroy
    redirect_to suppressions_path, notice: "Suppression removed."
  end

  private
    def suppression_params
      params.require(:suppression).permit(:email)
    end
end

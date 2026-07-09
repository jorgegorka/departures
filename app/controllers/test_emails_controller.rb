class TestEmailsController < ApplicationController
  allow_unonboarded_access
  before_action -> { authorize_capability! :send }

  def new
    @submission = EmailSubmission.new(project: Current.project, source: default_source)
  end

  def create
    @submission = EmailSubmission.new(submission_params.merge(project: Current.project, source: default_source))

    if email = @submission.save
      redirect_to email_path(email), notice: "Test email queued."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private
    def default_source
      Current.project&.sources&.order(:id)&.first
    end

    def submission_params
      params.require(:email_submission).permit(:from, :to, :subject, :html, :text)
    end
end

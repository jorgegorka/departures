class Emails::ResendsController < ApplicationController
  include EmailScoped

  before_action -> { authorize_capability! :send }

  def create
    if resent = @email.resend
      redirect_to email_path(resent), notice: "Email queued for resend."
    else
      redirect_to email_path(@email), alert: "Email could not be resent — recipients may be suppressed."
    end
  end
end

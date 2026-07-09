class Onboardings::CompletionsController < ApplicationController
  allow_unonboarded_access

  def create
    Current.workspace.mark_onboarded
    redirect_to root_path, notice: "Welcome to Departures!"
  end
end

class Onboardings::CompletionsController < ApplicationController
  allow_unonboarded_access

  def create
    if Current.workspace.nil?
      redirect_to new_workspace_path
    else
      Current.workspace.mark_onboarded
      redirect_to root_path, notice: "Welcome to Departures!"
    end
  end
end

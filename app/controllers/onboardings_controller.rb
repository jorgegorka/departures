class OnboardingsController < ApplicationController
  allow_unonboarded_access

  def show
    if Current.workspace.nil?
      redirect_to new_workspace_path
    else
      Current.workspace.start_setup
      @onboarding = Current.workspace.onboarding_for(Current.project)
    end
  end
end

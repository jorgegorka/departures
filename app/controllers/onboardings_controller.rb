class OnboardingsController < ApplicationController
  allow_unonboarded_access

  def show
    Current.workspace.start_setup
    @onboarding = Current.workspace.onboarding_for(Current.project)
  end
end

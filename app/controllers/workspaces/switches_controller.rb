class Workspaces::SwitchesController < ApplicationController
  allow_unonboarded_access
  allow_two_factor_unenrolled_access

  def create
    workspace = Current.user.workspaces.find(params[:workspace_id])
    session[:workspace_id] = workspace.id
    session.delete(:project_slug)
    redirect_to root_url
  end
end

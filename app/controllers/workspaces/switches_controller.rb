class Workspaces::SwitchesController < ApplicationController
  def create
    workspace = Current.user.workspaces.find(params[:workspace_id])
    session[:workspace_id] = workspace.id
    session.delete(:project_slug)
    redirect_to root_url
  end
end

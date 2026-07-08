class WorkspacesController < ApplicationController
  def new
    @workspace = Workspace.new
  end

  def create
    workspace = Workspace.create_with_owner(owner: Current.user, **workspace_params.to_h.symbolize_keys)
    session[:workspace_id] = workspace.id
    redirect_to root_url
  end

  private
    def workspace_params
      params.expect(workspace: [ :name ])
    end
end

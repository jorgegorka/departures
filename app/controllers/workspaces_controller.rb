class WorkspacesController < ApplicationController
  allow_unonboarded_access
  allow_two_factor_unenrolled_access
  before_action :set_workspace, only: %i[ edit update ]

  def new
    @workspace = Workspace.new
  end

  def create
    @workspace = Workspace.create_with_owner(owner: Current.user, **workspace_params.to_h.symbolize_keys)

    if @workspace.persisted?
      session[:workspace_id] = @workspace.id
      redirect_to root_url
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @workspace.update(settings_params)
      if @workspace.saved_change_to_require_two_factor?
        action = @workspace.require_two_factor? ? "workspace.two_factor_required" : "workspace.two_factor_requirement_removed"
        AuditEvent.record(action, subject: @workspace, workspace: @workspace)
      end
      redirect_to edit_workspace_path(@workspace), notice: "Workspace settings saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    def set_workspace
      @workspace = Current.user.workspaces.find(params[:id])
      authorize_capability! :manage_members, workspace: @workspace
    end

    def workspace_params
      params.expect(workspace: [ :name ])
    end

    def settings_params
      params.expect(workspace: [ :name, :require_two_factor ])
    end
end

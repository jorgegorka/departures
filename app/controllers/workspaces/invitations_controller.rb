class Workspaces::InvitationsController < ApplicationController
  before_action :set_workspace
  before_action -> { authorize_capability! :manage_members, workspace: @workspace }

  def new
    @invitation = @workspace.invitations.new
  end

  def create
    invitation = @workspace.invitations.create!(invitation_params)
    invitation.deliver_later
    redirect_to root_url, notice: "Invitation sent to #{invitation.email}"
  end

  private
    def set_workspace
      @workspace = Current.user.workspaces.find(params[:workspace_id])
    end

    def invitation_params
      params.expect(invitation: [ :email, :role ])
    end
end

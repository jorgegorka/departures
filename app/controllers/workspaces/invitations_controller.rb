class Workspaces::InvitationsController < ApplicationController
  allow_unonboarded_access
  before_action :set_workspace
  before_action -> { authorize_capability! :manage_members, workspace: @workspace }

  def new
    @invitation = @workspace.invitations.new
  end

  def create
    @invitation = @workspace.invitations.new(invitation_params)

    if @invitation.save
      @invitation.deliver_later
      AuditEvent.record("invitation.created", subject: @invitation, metadata: { email: @invitation.email, role: @invitation.role }, workspace: @workspace)
      redirect_to root_url, notice: "Invitation sent to #{@invitation.email}"
    else
      render :new, status: :unprocessable_entity
    end
  end

  private
    def set_workspace
      @workspace = Current.user.workspaces.find(params[:workspace_id])
    end

    def invitation_params
      params.expect(invitation: [ :email, :role ])
    end
end

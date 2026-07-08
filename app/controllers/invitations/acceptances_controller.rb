class Invitations::AcceptancesController < ApplicationController
  allow_unauthenticated_access

  before_action :set_invitation

  def new
    @user = User.new(email_address: @invitation.email)
  end

  def create
    if authenticated?
      @invitation.accept(user: Current.user)
    else
      user = User.create!(user_params)
      start_new_session_for user
      @invitation.accept(user: user)
    end

    redirect_to root_url, notice: "Welcome to #{@invitation.workspace.name}"
  end

  private
    def set_invitation
      @invitation = Invitation.find_by_token(params[:invitation_token]) or head :not_found
    end

    def user_params
      params.permit(:email_address, :password, :password_confirmation)
    end
end

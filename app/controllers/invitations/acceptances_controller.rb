class Invitations::AcceptancesController < ApplicationController
  allow_unauthenticated_access

  before_action :set_invitation

  def new
    @user = User.new(email_address: @invitation.email)
  end

  def create
    if authenticated?
      @invitation.accept(user: Current.user)
      redirect_to root_url, notice: "Welcome to #{@invitation.workspace.name}"
    else
      user = User.new(user_params)
      user.email_address = @invitation.email

      if user.save
        start_new_session_for user
        @invitation.accept(user: user)
        redirect_to root_url, notice: "Welcome to #{@invitation.workspace.name}"
      else
        @user = user
        render :new, status: :unprocessable_entity
      end
    end
  end

  private
    def set_invitation
      @invitation = Invitation.find_by_token(params[:invitation_token]) or head :not_found
    end

    def user_params
      params.permit(:password, :password_confirmation)
    end
end

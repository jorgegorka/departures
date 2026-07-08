class RegistrationsController < ApplicationController
  allow_unauthenticated_access

  before_action :ensure_registration_open

  def new
    @user = User.new
  end

  def create
    @user = User.create_owner(user_params)
    start_new_session_for @user
    redirect_to root_url
  end

  private
    def ensure_registration_open
      unless User.registration_open?
        head :not_found
      end
    end

    def user_params
      params.permit(:email_address, :password, :password_confirmation)
    end
end

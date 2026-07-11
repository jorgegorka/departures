class SessionsController < ApplicationController
  allow_unonboarded_access
  allow_two_factor_unenrolled_access
  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: "Try again later." }

  def index
    @sessions = Current.user.sessions.by_recent_activity
  end

  def new
  end

  def create
    if user = User.authenticate_by(params.permit(:email_address, :password))
      if user.two_factor_enabled?
        stash_pending_two_factor user
        redirect_to new_challenge_path
      else
        start_new_session_for user
        redirect_to after_authentication_url
      end
    else
      redirect_to new_session_path, alert: "Try another email address or password."
    end
  end

  def destroy
    session_record = params[:id] ? Current.user.sessions.find(params[:id]) : Current.session

    if session_record == Current.session
      terminate_session
      redirect_to new_session_path, status: :see_other
    else
      session_record.destroy
      redirect_to user_sessions_path, notice: "Session signed out."
    end
  end

  private
    def stash_pending_two_factor(user)
      cookies.signed[:pending_two_factor_user_id] = {
        value: user.id, expires: 10.minutes, httponly: true, same_site: :lax
      }
    end
end

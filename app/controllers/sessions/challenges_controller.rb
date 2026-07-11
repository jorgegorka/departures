class Sessions::ChallengesController < ApplicationController
  allow_unauthenticated_access
  allow_unonboarded_access
  allow_two_factor_unenrolled_access
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_challenge_path, alert: "Try again later." }
  before_action :set_pending_user

  def new
  end

  def create
    if @user.verify_totp(params[:code]) || @user.redeem_recovery_code(params[:code])
      cookies.delete(:pending_two_factor_user_id)
      start_new_session_for @user
      redirect_to after_authentication_url
    else
      redirect_to new_challenge_path, alert: "That code didn't work. Try the current code from your app, or a recovery code."
    end
  end

  private
    def set_pending_user
      @user = User.find_by(id: cookies.signed[:pending_two_factor_user_id])

      if @user.nil?
        redirect_to new_session_path, alert: "Please sign in again."
      end
    end
end

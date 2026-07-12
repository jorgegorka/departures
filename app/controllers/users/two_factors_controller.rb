class Users::TwoFactorsController < ApplicationController
  allow_unonboarded_access
  allow_two_factor_unenrolled_access

  before_action :redirect_enrolled, only: %i[ new create ]

  def new
    Current.user.prepare_two_factor
    @totp = Totp.new(Current.user.otp_secret)
  end

  def create
    if Current.user.authenticate(params[:password]) && (@recovery_codes = Current.user.enable_two_factor(params[:code]))
      render :create
    else
      redirect_to new_two_factor_path, alert: "Wrong password or code. Scan the QR code again and retry."
    end
  end

  def destroy
    if Current.user.authenticate(params[:password])
      Current.user.disable_two_factor
      redirect_to root_path, notice: "Two-factor authentication disabled."
    else
      redirect_to root_path, alert: "Wrong password — two-factor authentication is still enabled."
    end
  end

  private
    def redirect_enrolled
      if Current.user.two_factor_enabled?
        redirect_to user_sessions_path, notice: "Two-factor authentication is already enabled."
      end
    end
end

class Users::TwoFactorsController < ApplicationController
  allow_unonboarded_access
  allow_two_factor_unenrolled_access

  def new
    unless Current.user.two_factor_enabled?
      Current.user.prepare_two_factor
    end
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
end

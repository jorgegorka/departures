class Users::RecoveryCodesController < ApplicationController
  allow_unonboarded_access

  def create
    if Current.user.two_factor_enabled? && Current.user.authenticate(params[:password])
      @recovery_codes = Current.user.regenerate_recovery_codes
      render :create
    else
      redirect_to root_path, alert: "Wrong password — recovery codes unchanged."
    end
  end
end

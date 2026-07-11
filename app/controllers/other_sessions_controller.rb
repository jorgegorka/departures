class OtherSessionsController < ApplicationController
  allow_unonboarded_access
  allow_two_factor_unenrolled_access

  def destroy
    Current.user.sessions.where.not(id: Current.session.id).destroy_all
    redirect_to user_sessions_path, notice: "Signed out everywhere else."
  end
end

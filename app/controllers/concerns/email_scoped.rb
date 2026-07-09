module EmailScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_email
  end

  private
    def set_email
      if Current.project
        @email = Current.project.emails.find_by!(public_id: params[:email_id] || params[:id])
      else
        raise ActiveRecord::RecordNotFound
      end
    end
end

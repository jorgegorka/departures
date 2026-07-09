module RequiresProject
  extend ActiveSupport::Concern

  included do
    before_action :require_project
  end

  private
    def require_project
      if Current.project.nil?
        raise ActiveRecord::RecordNotFound
      end
    end
end

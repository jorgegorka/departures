module SetsCurrentWorkspaceAndProject
  extend ActiveSupport::Concern

  included do
    before_action :set_current_workspace, :set_current_project, :require_two_factor_enrollment, :require_onboarding
  end

  class_methods do
    def allow_unonboarded_access(**options)
      skip_before_action :require_onboarding, **options
    end

    def allow_two_factor_unenrolled_access(**options)
      skip_before_action :require_two_factor_enrollment, **options
    end
  end

  private
    def set_current_workspace
      if authenticated?
        Current.workspace = Current.user.workspaces.find_by(id: session[:workspace_id]) ||
          Current.user.workspaces.order(:id).first
      end
    end

    def set_current_project
      if Current.workspace
        Current.project = Current.workspace.projects.active.find_by(slug: session[:project_slug]) ||
          Current.workspace.projects.active.order(:id).first
      end
    end

    def require_two_factor_enrollment
      if Current.workspace&.require_two_factor? && Current.user&.two_factor_disabled?
        redirect_to new_two_factor_path, alert: "#{Current.workspace.name} requires two-factor authentication. Enable it to continue."
      end
    end

    def require_onboarding
      if Current.workspace&.needs_onboarding?
        redirect_to onboarding_path
      end
    end
end

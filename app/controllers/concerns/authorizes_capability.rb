module AuthorizesCapability
  extend ActiveSupport::Concern

  private
    def authorize_capability!(capability, workspace: Current.workspace)
      unless workspace&.capability?(Current.user, capability)
        head :forbidden
      end
    end
end

module AuthorizesCapability
  extend ActiveSupport::Concern

  private
    def authorize_capability!(capability)
      unless Current.workspace&.capability?(Current.user, capability)
        head :forbidden
      end
    end
end

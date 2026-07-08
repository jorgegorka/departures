class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :workspace, :project

  delegate :user, to: :session, allow_nil: true
end

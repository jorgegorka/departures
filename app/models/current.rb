class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :workspace, :project
  attribute :ip

  delegate :user, to: :session, allow_nil: true
end

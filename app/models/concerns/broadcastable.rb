# Live-activity broadcasting for project-owned records: a refresh stream
# action on [project, :activity], morphed by any subscribed dashboard view.
module Broadcastable
  extend ActiveSupport::Concern

  def broadcast_activity
    broadcast_refresh_to(project, :activity)
  end
end

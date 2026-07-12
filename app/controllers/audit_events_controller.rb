class AuditEventsController < ApplicationController
  before_action -> { authorize_capability! :view_audit_log }

  def index
    @audit_events = Current.workspace.audit_events
      .indexed_by(params[:group])
      .in_time_range(params[:range])
      .preloaded
      .reverse_chronologically
      .limit(200)
  end
end

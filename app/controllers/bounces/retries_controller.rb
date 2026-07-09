class Bounces::RetriesController < ApplicationController
  before_action -> { authorize_capability! :send }

  def create
    count = Current.project.emails.retry_soft_bounces(limit: 100)
    redirect_to bounces_path, notice: "#{count} #{"email".pluralize(count)} re-queued."
  end
end

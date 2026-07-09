module Workspace::Onboardable
  extend ActiveSupport::Concern

  def onboarded?
    onboarded_at.present?
  end

  def needs_onboarding?
    !onboarded?
  end

  def start_setup
    if setup_started_at.nil?
      update!(setup_started_at: Time.current)
    end
  end

  def mark_onboarded
    if needs_onboarding?
      update!(onboarded_at: Time.current)
    end
  end

  def onboarding_for(project)
    Workspace::Onboarding.new(self, project)
  end
end

class Workspace::Onboarding
  attr_reader :workspace, :project

  def initialize(workspace, project)
    @workspace = workspace
    @project = project
  end

  def source_added?
    project.present? && project.sources.any?
  end

  def domain_verified?
    project.present? && project.domains.verified.any?
  end

  def api_key_issued?
    project.present? && project.api_keys.any?
  end

  def test_email_sent?
    project.present? && project.emails.any?
  end

  def complete?
    source_added? && domain_verified? && api_key_issued? && test_email_sent?
  end
end

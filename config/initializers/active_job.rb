module DeparturesJobExtensions
  def self.prepended(base)
    base.attr_reader :workspace
  end

  def initialize(...)
    super
    @workspace = Current.workspace
  end

  def serialize
    super.merge("workspace" => @workspace&.to_gid&.to_s)
  end

  def deserialize(job_data)
    super
    if workspace_gid = job_data["workspace"]
      @workspace = GlobalID::Locator.locate(workspace_gid)
    end
  end

  def perform_now
    if workspace.present?
      Current.set(workspace: workspace) { super }
    else
      super
    end
  end
end

Rails.application.config.active_job.enqueue_after_transaction_commit = true

ActiveSupport.on_load(:active_job) do
  prepend DeparturesJobExtensions
end

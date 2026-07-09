class Domains::ChecksController < ApplicationController
  include RequiresProject
  allow_unonboarded_access

  before_action -> { authorize_capability! :manage_domains }

  def create
    domain = Current.project.domains.find(params[:domain_id])

    if domain.check
      redirect_to domains_path, notice: "#{domain.name} is verified."
    else
      redirect_to domains_path, alert: "#{domain.name} is not verified yet. DNS can take a while to propagate."
    end
  end
end

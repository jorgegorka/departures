class DomainsController < ApplicationController
  include RequiresProject

  skip_before_action :require_project, only: :index
  before_action -> { authorize_capability! :manage_domains }, only: %i[ create destroy ]

  def index
    if Current.project
      @domains = Current.project.domains.order(:name)
    end
  end

  def create
    if Current.project.sources.none?
      redirect_to domains_path, alert: "Add a source before adding domains."
    else
      @domain = Current.project.domains.new(domain_params)

      if @domain.save
        @domain.provision
        redirect_to domains_path, notice: "Domain added. Create the DNS records below, then re-check."
      else
        redirect_to domains_path, alert: @domain.errors.full_messages.to_sentence
      end
    end
  end

  def destroy
    Current.project.domains.find(params[:id]).decommission
    redirect_to domains_path, notice: "Domain removed."
  end

  private
    def domain_params
      params.require(:domain).permit(:name)
    end
end

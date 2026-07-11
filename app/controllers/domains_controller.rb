class DomainsController < ApplicationController
  include RequiresProject
  allow_unonboarded_access

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
        AuditEvent.record("domain.created", subject: @domain, metadata: { name: @domain.name })
        if @domain.provision
          redirect_to domains_path, notice: "Domain added. Create the DNS records below, then re-check."
        else
          redirect_to domains_path, alert: "#{@domain.name} was added but SES provisioning failed — re-check DNS later."
        end
      else
        redirect_to domains_path, alert: @domain.errors.full_messages.to_sentence
      end
    end
  end

  def destroy
    domain = Current.project.domains.find(params[:id])
    domain.decommission
    AuditEvent.record("domain.destroyed", metadata: { name: domain.name })
    redirect_to domains_path, notice: "Domain removed."
  end

  private
    def domain_params
      params.require(:domain).permit(:name)
    end
end

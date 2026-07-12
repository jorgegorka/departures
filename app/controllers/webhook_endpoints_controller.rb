class WebhookEndpointsController < ApplicationController
  include RequiresProject

  skip_before_action :require_project, only: :index
  before_action -> { authorize_capability! :manage_webhooks }, only: %i[ new create edit update destroy ]
  before_action :set_webhook_endpoint, only: %i[ show edit update destroy ]

  def index
    if Current.project
      @webhook_endpoints = Current.project.webhook_endpoints.order(:url)
    end
  end

  def show
    @deliveries = @webhook_endpoint.deliveries.reverse_chronologically.limit(50)
  end

  def new
    @webhook_endpoint = Current.project.webhook_endpoints.new
  end

  def create
    @webhook_endpoint = Current.project.webhook_endpoints.new(webhook_endpoint_params)

    if @webhook_endpoint.save
      AuditEvent.record("webhook_endpoint.created", subject: @webhook_endpoint, metadata: { url: @webhook_endpoint.url })
      render :create
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @webhook_endpoint.update(webhook_endpoint_params)
      AuditEvent.record("webhook_endpoint.updated", subject: @webhook_endpoint, metadata: { url: @webhook_endpoint.url })
      redirect_to webhook_endpoints_path, notice: "Endpoint updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @webhook_endpoint.destroy
    AuditEvent.record("webhook_endpoint.destroyed", metadata: { url: @webhook_endpoint.url })
    redirect_to webhook_endpoints_path, notice: "Endpoint removed."
  end

  private
    def set_webhook_endpoint
      @webhook_endpoint = Current.project.webhook_endpoints.find(params[:id])
    end

    def webhook_endpoint_params
      params.require(:webhook_endpoint).permit(:url, :active, events: [])
    end
end

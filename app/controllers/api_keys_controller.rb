class ApiKeysController < ApplicationController
  include RequiresProject

  skip_before_action :require_project, only: :index
  before_action -> { authorize_capability! :manage_api_keys }, except: :index

  def index
    if Current.project
      @api_keys = Current.project.api_keys.order(created_at: :desc)
    end
  end

  def new
    @api_key = Current.project.api_keys.new
  end

  def create
    @api_key = ApiKey.issue(project: Current.project, name: api_key_params[:name],
      scopes: Array(api_key_params[:scopes]).reject(&:blank?), expires_in: expires_in)
    render :create
  end

  def destroy
    Current.project.api_keys.find(params[:id]).revoke
    redirect_to api_keys_path, notice: "API key revoked."
  end

  private
    def api_key_params
      params.require(:api_key).permit(:name, :expires_in, scopes: [])
    end

    def expires_in
      api_key_params[:expires_in].presence&.to_i&.days
    end
end

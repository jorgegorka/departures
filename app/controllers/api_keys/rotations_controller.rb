class ApiKeys::RotationsController < ApplicationController
  include RequiresProject
  allow_unonboarded_access

  before_action -> { authorize_capability! :manage_api_keys }

  def create
    @api_key = Current.project.api_keys.find(params[:api_key_id]).rotate
    render "api_keys/create"
  end
end

class Api::BaseController < ActionController::API
  before_action :authenticate_api_key
  before_action :ensure_scope

  # Declared after the auth before_action so @api_key is always set when the
  # limiter runs (actionpack registers rate_limit as a before_action in
  # declaration order — risk #5). Fallback if that ever changes:
  # by: -> { request.headers["Authorization"].to_s }
  rate_limit to: 60, within: 1.minute, by: -> { @api_key.id }, scope: :api,
    with: -> { render json: { error: "Too many requests" }, status: :too_many_requests }

  private
    def authenticate_api_key
      @api_key = ApiKey.authenticate_by_token(bearer_token)

      if @api_key
        Current.workspace = @api_key.workspace
        Current.project = @api_key.project
        @api_key.touch_usage(ip: request.remote_ip, user_agent: request.user_agent)
      else
        render json: { error: "Unauthorized" }, status: :unauthorized
      end
    end

    def bearer_token
      request.headers["Authorization"].to_s[/\ABearer (.+)\z/, 1]
    end

    def ensure_scope
      unless @api_key.allows?(required_scope)
        render json: { error: "Forbidden: this key is missing the #{required_scope} scope" }, status: :forbidden
      end
    end

    def required_scope
      if request.get? || request.head?
        "read:activity"
      else
        "send"
      end
    end
end

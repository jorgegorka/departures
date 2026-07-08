class Api::EmailsController < Api::BaseController
  before_action :set_source, only: :create

  def index
    emails = Current.project.emails.order(created_at: :desc).limit(50)

    render json: { data: emails.map { |email| { id: email.public_id, status: email.status, created_at: email.created_at } } }
  end

  def create
    @submission = EmailSubmission.new(submission_attributes)

    email = IdempotencyKey.replay_or_record(api_key: @api_key,
      key: request.headers["Idempotency-Key"], fingerprint: request_fingerprint) do
      @submission.save
    end

    if email
      render json: { id: email.public_id }, status: :accepted
    else
      render json: { errors: @submission.errors.full_messages }, status: :unprocessable_entity
    end
  rescue IdempotencyKey::MismatchError
    render json: { error: "Idempotency-Key was already used with a different request body" }, status: :conflict
  end

  private
    def set_source
      @source = Current.project.sources.find_by(environment: params.fetch(:environment, Current.project.default_environment))

      if @source.nil?
        render json: { errors: [ "No source is configured for this environment" ] }, status: :unprocessable_entity
      end
    end

    def submission_attributes
      params.permit(:from, :subject, :html, :text, :template_id,
        to: [], cc: [], bcc: [], headers: {}, tags: {},
        attachments: [ %i[ filename content_type content ] ])
        .to_h.merge(project: Current.project, source: @source, api_key: @api_key)
    end

    def request_fingerprint
      Digest::SHA256.hexdigest(request.raw_post)
    end
end

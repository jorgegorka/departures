require "test_helper"

class Api::EmailsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  ACME_FULL_TOKEN = "dp_#{"acme" * 12}".freeze
  ACME_READ_ONLY_TOKEN = "dp_#{"read" * 12}".freeze
  ACME_SEND_ONLY_TOKEN = "dp_#{"mail" * 12}".freeze
  ACME_REVOKED_TOKEN = "dp_#{"gone" * 12}".freeze
  ACME_EXPIRED_TOKEN = "dp_#{"late" * 12}".freeze
  GLOBEX_FULL_TOKEN = "dp_#{"glob" * 12}".freeze

  setup do
    Rails.cache.clear
  end

  def valid_payload(**overrides)
    { from: "hello@acme.com", to: [ "user@example.com" ], subject: "Hi", html: "<p>Hi</p>" }.merge(overrides)
  end

  def auth(token)
    { "Authorization" => "Bearer #{token}" }
  end

  def post_email(token: ACME_FULL_TOKEN, payload: valid_payload, headers: {})
    post api_emails_url, params: payload, headers: auth(token).merge(headers), as: :json
  end

  # --- Authentication (401) ---

  test "missing bearer token is unauthorized" do
    post api_emails_url, params: valid_payload, as: :json

    assert_response :unauthorized
    assert_equal "Unauthorized", response.parsed_body["error"]
  end

  test "unknown, revoked, and expired tokens are unauthorized" do
    [ "dp_bogus", ACME_REVOKED_TOKEN, ACME_EXPIRED_TOKEN ].each do |token|
      post_email(token: token)

      assert_response :unauthorized
    end
  end

  # --- Scope matrix (403) ---

  test "POST requires the send scope" do
    post_email(token: ACME_READ_ONLY_TOKEN)

    assert_response :forbidden
    assert_includes response.parsed_body["error"], "send"
  end

  test "GET requires the read:activity scope" do
    get api_emails_url, headers: auth(ACME_SEND_ONLY_TOKEN)

    assert_response :forbidden

    get api_emails_url, headers: auth(ACME_READ_ONLY_TOKEN)

    assert_response :success
  end

  # --- Create (202) ---

  test "a valid submission is accepted with the public id" do
    assert_difference -> { Email.count }, +1 do
      post_email
    end

    assert_response :accepted
    email = Email.order(:id).last
    assert_equal email.public_id, response.parsed_body["id"]
    assert_equal projects(:acme_default), email.project
    assert_equal sources(:acme_production), email.source
    assert_equal api_keys(:acme_full), email.api_key
  end

  test "emails are created under the key's project, not any other tenant" do
    post_email(token: GLOBEX_FULL_TOKEN, payload: valid_payload(from: "hello@globex.com"))

    assert_response :accepted
    assert_equal projects(:globex_default), Email.order(:id).last.project
  end

  test "authenticated requests touch key usage telemetry" do
    post_email

    assert api_keys(:acme_full).reload.last_used_at.present?
  end

  # --- Validation errors (422) ---

  test "an invalid submission returns the error list" do
    post_email(payload: valid_payload(to: [], html: nil, subject: nil))

    assert_response :unprocessable_entity
    errors = response.parsed_body["errors"]
    assert_kind_of Array, errors
    assert errors.any? { |e| e.include?("recipient") }
  end

  test "suppressed recipients are rejected listing the addresses" do
    post_email(payload: valid_payload(to: [ "blocked@example.com" ]))

    assert_response :unprocessable_entity
    assert response.parsed_body["errors"].any? { |e| e.include?("blocked@example.com") }
  end

  test "an unknown environment returns 422" do
    post_email(payload: valid_payload(environment: "staging"))

    assert_response :unprocessable_entity
  end

  test "omitting environment falls back to the project's stored default_environment" do
    project = projects(:acme_default)
    project.update!(default_environment: "staging")
    staging_source = project.sources.create!(
      workspace: project.workspace, name: "Acme staging", environment: "staging",
      region: "eu-west-1", aws_access_key_id: "AKIAACMESTAGING", aws_secret_access_key: "acme-staging-secret",
      webhook_token: "acme-webhook-token-staging-1", retention_days: 30)

    post_email

    assert_response :accepted
    assert_equal staging_source, Email.order(:id).last.source
  end

  test "sends with a template and variables" do
    post_email(token: ACME_SEND_ONLY_TOKEN,
      payload: { from: "hello@acme.com", to: [ "user@example.com" ],
                 template_id: "welcome", variables: { name: "Ada", company: "Acme" } })

    assert_response :accepted
    assert_equal "Welcome, Ada!", Email.order(:id).last.subject
  end

  # --- Idempotency (replay + 409) ---

  test "replaying an idempotency key returns the same email without creating another" do
    post_email(headers: { "Idempotency-Key" => "req-42" })
    assert_response :accepted
    first_id = response.parsed_body["id"]

    assert_no_difference -> { Email.count } do
      post_email(headers: { "Idempotency-Key" => "req-42" })
    end

    assert_response :accepted
    assert_equal first_id, response.parsed_body["id"]
  end

  test "reusing an idempotency key with a different body conflicts" do
    post_email(headers: { "Idempotency-Key" => "req-42" })

    post_email(payload: valid_payload(subject: "Changed"), headers: { "Idempotency-Key" => "req-42" })

    assert_response :conflict
    assert response.parsed_body["error"].present?
  end

  test "failed validations are not recorded against the idempotency key" do
    post_email(payload: valid_payload(to: []), headers: { "Idempotency-Key" => "req-43" })
    assert_response :unprocessable_entity

    assert_difference -> { Email.count }, +1 do
      post_email(headers: { "Idempotency-Key" => "req-43" })
    end

    assert_response :accepted
  end

  # --- Rate limiting (429, risk #5) ---

  test "requests beyond 60 per minute per key are rejected" do
    60.times do
      get api_emails_url, headers: auth(ACME_FULL_TOKEN)
      assert_response :success
    end

    get api_emails_url, headers: auth(ACME_FULL_TOKEN)

    assert_response :too_many_requests
    assert_equal "Too many requests", response.parsed_body["error"]
  end

  test "the rate limiter runs after authentication, so unauthenticated requests get 401 not an error" do
    post api_emails_url, params: valid_payload, as: :json

    assert_response :unauthorized
  end

  # --- Index ---

  test "index returns the project's latest emails" do
    get api_emails_url, headers: auth(ACME_FULL_TOKEN)

    assert_response :success
    data = response.parsed_body["data"]
    assert data.any? { |row| row["id"] == emails(:acme_welcome).public_id }
    assert(data.all? { |row| row.key?("status") && row.key?("created_at") })
  end

  # --- Delivery wiring (Phase 2) ---

  test "an accepted submission stores the MIME and enqueues delivery" do
    assert_enqueued_with(job: SendEmailJob) do
      post_email
    end

    assert_response :accepted
    email = Email.order(:id).last
    assert_equal "queued", email.status
    assert Email::MimeStore.root.join(email.mime_path).exist?
  end

  test "an idempotent replay does not enqueue a second delivery" do
    post_email(headers: { "Idempotency-Key" => "req-90" })
    assert_response :accepted

    assert_no_enqueued_jobs only: SendEmailJob do
      post_email(headers: { "Idempotency-Key" => "req-90" })
    end

    assert_response :accepted
  end

  test "a rejected submission enqueues nothing" do
    assert_no_enqueued_jobs only: SendEmailJob do
      post_email(payload: valid_payload(to: []))
    end

    assert_response :unprocessable_entity
  end
end

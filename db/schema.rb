# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_11_114015) do
  create_table "api_keys", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "key_hash", null: false
    t.datetime "last_used_at"
    t.string "last_used_ip"
    t.string "last_used_user_agent"
    t.string "name"
    t.string "prefix", null: false
    t.integer "project_id", null: false
    t.datetime "revoked_at"
    t.json "scopes", default: [], null: false
    t.datetime "updated_at", null: false
    t.integer "workspace_id", null: false
    t.index ["key_hash"], name: "index_api_keys_on_key_hash", unique: true
    t.index ["project_id"], name: "index_api_keys_on_project_id"
    t.index ["workspace_id"], name: "index_api_keys_on_workspace_id"
  end

  create_table "audit_events", force: :cascade do |t|
    t.string "action", null: false
    t.datetime "created_at", null: false
    t.string "ip"
    t.json "metadata", default: {}, null: false
    t.integer "subject_id"
    t.string "subject_type"
    t.integer "user_id"
    t.integer "workspace_id"
    t.index ["subject_type", "subject_id"], name: "index_audit_events_on_subject"
    t.index ["user_id"], name: "index_audit_events_on_user_id"
    t.index ["workspace_id", "action"], name: "index_audit_events_on_workspace_id_and_action"
    t.index ["workspace_id", "created_at"], name: "index_audit_events_on_workspace_id_and_created_at"
    t.index ["workspace_id"], name: "index_audit_events_on_workspace_id"
  end

  create_table "domains", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "dkim_tokens", default: [], null: false
    t.datetime "last_checked_at"
    t.string "name", null: false
    t.integer "project_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.integer "workspace_id", null: false
    t.index ["project_id", "name"], name: "index_domains_on_project_id_and_name", unique: true
    t.index ["project_id"], name: "index_domains_on_project_id"
    t.index ["workspace_id"], name: "index_domains_on_workspace_id"
  end

  create_table "email_attachments", force: :cascade do |t|
    t.integer "byte_size", default: 0, null: false
    t.string "content_type"
    t.datetime "created_at", null: false
    t.integer "email_id", null: false
    t.string "filename", null: false
    t.datetime "updated_at", null: false
    t.index ["email_id"], name: "index_email_attachments_on_email_id"
  end

  create_table "email_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "email_id", null: false
    t.string "event_type", null: false
    t.string "ip"
    t.datetime "occurred_at", null: false
    t.json "payload", default: {}, null: false
    t.string "recipient"
    t.string "ses_message_id"
    t.datetime "updated_at", null: false
    t.string "url"
    t.string "user_agent"
    t.index ["email_id", "occurred_at"], name: "index_email_events_on_email_id_and_occurred_at"
    t.index ["email_id"], name: "index_email_events_on_email_id"
  end

  create_table "email_recipients", force: :cascade do |t|
    t.string "address", null: false
    t.datetime "created_at", null: false
    t.integer "email_id", null: false
    t.string "kind", default: "to", null: false
    t.datetime "updated_at", null: false
    t.index ["address"], name: "index_email_recipients_on_address"
    t.index ["email_id"], name: "index_email_recipients_on_email_id"
  end

  create_table "emails", force: :cascade do |t|
    t.integer "api_key_id"
    t.string "bounce_type"
    t.datetime "created_at", null: false
    t.string "failure_reason"
    t.string "from", null: false
    t.json "headers", default: {}, null: false
    t.text "html_body"
    t.string "mime_path"
    t.integer "mime_size"
    t.integer "project_id", null: false
    t.string "public_id", null: false
    t.datetime "resent_at"
    t.string "ses_message_id"
    t.integer "source_id", null: false
    t.string "status", default: "queued", null: false
    t.string "subject"
    t.json "tags", default: {}, null: false
    t.text "text_body"
    t.datetime "updated_at", null: false
    t.integer "workspace_id", null: false
    t.index ["api_key_id"], name: "index_emails_on_api_key_id"
    t.index ["project_id", "bounce_type"], name: "index_emails_on_project_id_and_bounce_type"
    t.index ["project_id", "created_at"], name: "index_emails_on_project_id_and_created_at"
    t.index ["project_id", "status", "created_at"], name: "index_emails_on_project_id_and_status_and_created_at"
    t.index ["project_id"], name: "index_emails_on_project_id"
    t.index ["public_id"], name: "index_emails_on_public_id", unique: true
    t.index ["ses_message_id"], name: "index_emails_on_ses_message_id"
    t.index ["source_id"], name: "index_emails_on_source_id"
    t.index ["workspace_id"], name: "index_emails_on_workspace_id"
  end

  create_table "idempotency_keys", force: :cascade do |t|
    t.integer "api_key_id", null: false
    t.datetime "created_at", null: false
    t.integer "email_id", null: false
    t.datetime "expires_at", null: false
    t.string "fingerprint", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.index ["api_key_id", "key"], name: "index_idempotency_keys_on_api_key_id_and_key", unique: true
    t.index ["api_key_id"], name: "index_idempotency_keys_on_api_key_id"
    t.index ["email_id"], name: "index_idempotency_keys_on_email_id"
  end

  create_table "invitations", force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.datetime "expires_at", null: false
    t.integer "invited_by_id", null: false
    t.string "role", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.integer "workspace_id", null: false
    t.index ["invited_by_id"], name: "index_invitations_on_invited_by_id"
    t.index ["token_digest"], name: "index_invitations_on_token_digest", unique: true
    t.index ["workspace_id"], name: "index_invitations_on_workspace_id"
  end

  create_table "memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.integer "workspace_id", null: false
    t.index ["user_id"], name: "index_memberships_on_user_id"
    t.index ["workspace_id", "user_id"], name: "index_memberships_on_workspace_id_and_user_id", unique: true
    t.index ["workspace_id"], name: "index_memberships_on_workspace_id"
  end

  create_table "projects", force: :cascade do |t|
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.string "default_environment", default: "production", null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.integer "workspace_id", null: false
    t.index ["workspace_id", "slug"], name: "index_projects_on_workspace_id_and_slug", unique: true
    t.index ["workspace_id"], name: "index_projects_on_workspace_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "last_active_at"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "sources", force: :cascade do |t|
    t.string "aws_access_key_id"
    t.string "aws_secret_access_key"
    t.string "configuration_set"
    t.datetime "created_at", null: false
    t.string "default_from"
    t.string "environment", default: "production", null: false
    t.json "last_quota"
    t.datetime "last_quota_checked_at"
    t.string "name"
    t.integer "project_id", null: false
    t.string "region", default: "us-east-1", null: false
    t.integer "retention_days", default: 30, null: false
    t.datetime "updated_at", null: false
    t.string "webhook_token"
    t.integer "workspace_id", null: false
    t.index ["project_id", "environment"], name: "index_sources_on_project_id_and_environment", unique: true
    t.index ["project_id"], name: "index_sources_on_project_id"
    t.index ["webhook_token"], name: "index_sources_on_webhook_token", unique: true
    t.index ["workspace_id"], name: "index_sources_on_workspace_id"
  end

  create_table "suppressions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.datetime "expires_at"
    t.integer "project_id", null: false
    t.string "reason", null: false
    t.datetime "updated_at", null: false
    t.integer "workspace_id", null: false
    t.index ["project_id", "email"], name: "index_suppressions_on_project_id_and_email", unique: true
    t.index ["project_id"], name: "index_suppressions_on_project_id"
    t.index ["workspace_id"], name: "index_suppressions_on_workspace_id"
  end

  create_table "templates", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "html_body"
    t.string "name", null: false
    t.integer "project_id", null: false
    t.string "slug", null: false
    t.string "subject"
    t.text "text_body"
    t.datetime "updated_at", null: false
    t.integer "workspace_id", null: false
    t.index ["project_id", "slug"], name: "index_templates_on_project_id_and_slug", unique: true
    t.index ["project_id"], name: "index_templates_on_project_id"
    t.index ["workspace_id"], name: "index_templates_on_workspace_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.integer "otp_consumed_timestep"
    t.datetime "otp_enabled_at"
    t.json "otp_recovery_codes", default: [], null: false
    t.string "otp_secret"
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  create_table "webhook_deliveries", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.datetime "created_at", null: false
    t.integer "email_id"
    t.string "event_type", null: false
    t.integer "http_status"
    t.datetime "last_attempted_at"
    t.integer "latency_ms"
    t.json "payload", default: {}, null: false
    t.string "response_body"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.integer "webhook_endpoint_id", null: false
    t.integer "workspace_id", null: false
    t.index ["email_id"], name: "index_webhook_deliveries_on_email_id"
    t.index ["webhook_endpoint_id", "created_at"], name: "index_webhook_deliveries_on_webhook_endpoint_id_and_created_at"
    t.index ["webhook_endpoint_id"], name: "index_webhook_deliveries_on_webhook_endpoint_id"
    t.index ["workspace_id"], name: "index_webhook_deliveries_on_workspace_id"
  end

  create_table "webhook_endpoints", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.json "events", default: [], null: false
    t.integer "project_id", null: false
    t.string "secret"
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.integer "workspace_id", null: false
    t.index ["project_id"], name: "index_webhook_endpoints_on_project_id"
    t.index ["workspace_id"], name: "index_webhook_endpoints_on_workspace_id"
  end

  create_table "webhook_logs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "error"
    t.string "message_type"
    t.json "payload", default: {}, null: false
    t.datetime "processed_at"
    t.integer "source_id", null: false
    t.string "status", default: "received", null: false
    t.datetime "updated_at", null: false
    t.integer "workspace_id", null: false
    t.index ["source_id", "created_at"], name: "index_webhook_logs_on_source_id_and_created_at"
    t.index ["source_id"], name: "index_webhook_logs_on_source_id"
    t.index ["workspace_id"], name: "index_webhook_logs_on_workspace_id"
  end

  create_table "workspaces", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "onboarded_at"
    t.integer "owner_id", null: false
    t.boolean "require_two_factor", default: false, null: false
    t.datetime "setup_started_at"
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_id"], name: "index_workspaces_on_owner_id"
    t.index ["slug"], name: "index_workspaces_on_slug", unique: true
  end

  add_foreign_key "api_keys", "projects"
  add_foreign_key "api_keys", "workspaces"
  add_foreign_key "domains", "projects"
  add_foreign_key "domains", "workspaces"
  add_foreign_key "email_attachments", "emails"
  add_foreign_key "email_events", "emails"
  add_foreign_key "email_recipients", "emails"
  add_foreign_key "emails", "api_keys"
  add_foreign_key "emails", "projects"
  add_foreign_key "emails", "sources"
  add_foreign_key "emails", "workspaces"
  add_foreign_key "idempotency_keys", "api_keys"
  add_foreign_key "idempotency_keys", "emails"
  add_foreign_key "invitations", "users", column: "invited_by_id"
  add_foreign_key "invitations", "workspaces"
  add_foreign_key "memberships", "users"
  add_foreign_key "memberships", "workspaces"
  add_foreign_key "projects", "workspaces"
  add_foreign_key "sessions", "users"
  add_foreign_key "sources", "projects"
  add_foreign_key "sources", "workspaces"
  add_foreign_key "suppressions", "projects"
  add_foreign_key "suppressions", "workspaces"
  add_foreign_key "templates", "projects"
  add_foreign_key "templates", "workspaces"
  add_foreign_key "webhook_deliveries", "emails", on_delete: :nullify
  add_foreign_key "webhook_deliveries", "webhook_endpoints"
  add_foreign_key "webhook_deliveries", "workspaces"
  add_foreign_key "webhook_endpoints", "projects"
  add_foreign_key "webhook_endpoints", "workspaces"
  add_foreign_key "webhook_logs", "sources"
  add_foreign_key "webhook_logs", "workspaces"
  add_foreign_key "workspaces", "users", column: "owner_id"
end

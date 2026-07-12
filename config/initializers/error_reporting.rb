# Unhandled request and job exceptions flow through the Rails error reporter
# (ActionDispatch executor + Active Job both report unhandled errors since 7.1).
# Alert the operator by email in production only.
Rails.application.config.after_initialize do
  if Rails.env.production?
    Rails.error.subscribe(Ops::ErrorNotifier.new)
  end
end

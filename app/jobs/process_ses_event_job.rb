class ProcessSesEventJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError

  def perform(webhook_log)
    webhook_log.process
  end
end

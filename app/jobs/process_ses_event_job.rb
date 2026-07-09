class ProcessSesEventJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError

  # Solid Queue does not auto-retry, but ingestion (transactional rollback +
  # received? guard) and subscription confirmation (an un-rescued Net::HTTP GET)
  # both assume retries — one DNS blip would otherwise strand a subscription for
  # good, since the controller already 200'd and SNS won't redeliver.
  retry_on SocketError, Timeout::Error, SystemCallError, IOError, OpenSSL::SSL::SSLError,
    wait: :polynomially_longer, attempts: 5 do |job, error|
    job.arguments.first.update!(status: "failed", error: error.message)
  end

  def perform(webhook_log)
    webhook_log.process
  end
end

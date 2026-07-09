class SendEmailJob < ApplicationJob
  queue_as :default

  retry_on Aws::SESV2::Errors::ServiceError, wait: :polynomially_longer, attempts: 3 do |job, error|
    job.arguments.first.mark_failed(error.message)
  end

  # Networking failures (connection reset, DNS, timeouts) descend from StandardError,
  # not ServiceError, so they need their own retry — otherwise they strand the email.
  retry_on Seahorse::Client::NetworkingError, wait: :polynomially_longer, attempts: 3 do |job, error|
    job.arguments.first.mark_failed(error.message)
  end

  def perform(email)
    email.deliver
  end
end

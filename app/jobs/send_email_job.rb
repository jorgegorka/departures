class SendEmailJob < ApplicationJob
  queue_as :default

  retry_on Aws::SESV2::Errors::ServiceError, wait: :polynomially_longer, attempts: 3 do |job, error|
    job.arguments.first.mark_failed(error.message)
  end

  def perform(email)
    email.deliver
  end
end

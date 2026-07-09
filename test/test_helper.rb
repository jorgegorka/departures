ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Wipes an email and everything that hangs off it, so tests that assert on
    # absolute counts or unique indexes start from a clean slate regardless of
    # fixtures. Children are deleted before parents to respect foreign keys.
    def wipe_send_domain
      IdempotencyKey.delete_all
      EmailRecipient.delete_all
      EmailAttachment.delete_all
      Email.delete_all
    end

    # Wipes the whole workspace graph — accounts and everything they own,
    # including the send domain — for tests that need a truly empty database
    # (e.g. registration-open behaviour). Only safe under transactional tests,
    # where the deletions roll back with the test.
    def wipe_workspace_records
      wipe_send_domain
      Membership.delete_all
      Source.delete_all
      ApiKey.delete_all
      Suppression.delete_all
      Project.delete_all
      Workspace.delete_all
      Session.delete_all
      User.delete_all
    end
  end
end

module SignInHelper
  def sign_in_as(user)
    post session_url, params: { email_address: user.email_address, password: "secret123456" }
  end
end

class ActionDispatch::IntegrationTest
  include SignInHelper
end

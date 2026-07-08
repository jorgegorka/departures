require "test_helper"

class WorkspaceContextTest < ActiveJob::TestCase
  class ProbeJob < ApplicationJob
    cattr_accessor :seen_workspace

    def perform
      self.class.seen_workspace = Current.workspace
    end
  end

  test "jobs restore the workspace that was current at enqueue time" do
    Current.workspace = workspaces(:acme)
    ProbeJob.perform_later
    Current.reset

    perform_enqueued_jobs

    assert_equal workspaces(:acme), ProbeJob.seen_workspace
  end

  test "jobs enqueued without a workspace run with none" do
    ProbeJob.seen_workspace = :sentinel
    ProbeJob.perform_later

    perform_enqueued_jobs

    assert_nil ProbeJob.seen_workspace
  end
end

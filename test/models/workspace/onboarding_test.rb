require "test_helper"

class Workspace::OnboardingTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
    @workspace = workspaces(:acme)
    @project = projects(:acme_default)
  end

  test "onboarded? and needs_onboarding? read the timestamp" do
    assert @workspace.onboarded?
    assert_not @workspace.needs_onboarding?

    @workspace.update!(onboarded_at: nil)
    assert @workspace.needs_onboarding?
  end

  test "start_setup stamps once and never re-stamps" do
    @workspace.update!(setup_started_at: nil)

    @workspace.start_setup
    first_stamp = @workspace.reload.setup_started_at
    assert first_stamp.present?

    travel 1.hour do
      @workspace.start_setup
      assert_equal first_stamp, @workspace.reload.setup_started_at
    end
  end

  test "mark_onboarded stamps the workspace" do
    @workspace.update!(onboarded_at: nil)

    @workspace.mark_onboarded

    assert @workspace.reload.onboarded?
  end

  test "the checklist reflects the project's real state" do
    onboarding = @workspace.onboarding_for(@project)

    assert onboarding.source_added?
    assert onboarding.domain_verified?
    assert onboarding.test_email_sent?

    # Clear the project's keys so issuing one is the last outstanding step.
    @project.api_keys.destroy_all
    incomplete = @workspace.onboarding_for(@project)
    assert_not incomplete.api_key_issued?
    assert_not incomplete.complete?

    ApiKey.issue(project: @project, scopes: %w[ send ])
    assert @workspace.onboarding_for(@project.reload).complete?
  end

  test "the checklist is all false without a project" do
    onboarding = @workspace.onboarding_for(nil)

    assert_not onboarding.source_added?
    assert_not onboarding.complete?
  end
end

require "test_helper"

class SourceTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "workspace defaults to the project's workspace" do
    source = projects(:acme_default).sources.create!(environment: "staging",
      aws_access_key_id: "AKIA123", aws_secret_access_key: "secret123")

    assert_equal workspaces(:acme), source.workspace
  end

  test "aws credentials are encrypted at rest" do
    source = sources(:acme_production)

    assert_equal "AKIAACMEEXAMPLE", source.aws_access_key_id
    assert_not_equal "AKIAACMEEXAMPLE", source.ciphertext_for(:aws_access_key_id)
    assert_not_equal "acme-secret", source.ciphertext_for(:aws_secret_access_key)
  end

  test "webhook_token is generated on create" do
    source = projects(:acme_default).sources.create!(environment: "staging")

    assert source.webhook_token.present?
    assert_operator source.webhook_token.length, :>=, 24
  end

  test "environment is unique per project" do
    assert_raises ActiveRecord::RecordInvalid do
      projects(:acme_default).sources.create!(environment: "production")
    end
  end

  test "ses_client is memoized and injectable" do
    source = sources(:acme_production)
    stubbed = Aws::SESV2::Client.new(stub_responses: true)

    source.ses_client = stubbed

    assert_same stubbed, source.ses_client
    assert_same stubbed, source.ses_client
  end

  test "ses_client builds a client for the source's region" do
    client = sources(:acme_production).ses_client

    assert_instance_of Aws::SESV2::Client, client
    assert_equal "eu-west-1", client.config.region
  end
end

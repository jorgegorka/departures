require "test_helper"

class SourceTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)

    # Create sources with encrypted attributes through the ORM
    unless Source.exists?(environment: "production", project: projects(:acme_default))
      Source.create!(
        project: projects(:acme_default),
        workspace: workspaces(:acme),
        name: "Acme production",
        environment: "production",
        region: "eu-west-1",
        aws_access_key_id: "AKIAACMEEXAMPLE",
        aws_secret_access_key: "acme-secret",
        retention_days: 30
      )
    end

    unless Source.exists?(environment: "production", project: projects(:globex_default))
      Source.create!(
        project: projects(:globex_default),
        workspace: workspaces(:globex),
        name: "Globex production",
        environment: "production",
        region: "us-east-1",
        aws_access_key_id: "AKIAGLOBEXEXAMPLE",
        aws_secret_access_key: "globex-secret",
        retention_days: 30
      )
    end
  end

  test "workspace defaults to the project's workspace" do
    source = projects(:acme_default).sources.create!(environment: "staging",
      aws_access_key_id: "AKIA123", aws_secret_access_key: "secret123")

    assert_equal workspaces(:acme), source.workspace
  end

  test "aws credentials are encrypted at rest" do
    source = Source.find_by(environment: "production", project: projects(:acme_default))

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
    source = Source.find_by(environment: "production", project: projects(:acme_default))
    stubbed = Aws::SESV2::Client.new(stub_responses: true)

    source.ses_client = stubbed

    assert_same stubbed, source.ses_client
    assert_same stubbed, source.ses_client
  end

  test "ses_client builds a client for the source's region" do
    client = Source.find_by(environment: "production", project: projects(:acme_default)).ses_client

    assert_instance_of Aws::SESV2::Client, client
    assert_equal "eu-west-1", client.config.region
  end
end

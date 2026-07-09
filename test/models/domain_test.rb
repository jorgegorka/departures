require "test_helper"

class DomainTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "workspace defaults from the project" do
    domain = projects(:acme_default).domains.create!(name: "mail.acme.com")

    assert_equal workspaces(:acme), domain.workspace
    assert domain.pending?
  end

  test "name is normalized, validated, and unique per project" do
    domain = projects(:acme_default).domains.create!(name: "  Mail.Acme.COM  ")
    assert_equal "mail.acme.com", domain.name

    duplicate = projects(:acme_default).domains.build(name: "MAIL.ACME.COM")
    assert_not duplicate.valid?

    other_project = projects(:globex_default).domains.build(name: "mail.acme.com")
    assert other_project.valid?

    assert_not projects(:acme_default).domains.build(name: "not a domain").valid?
    assert_not projects(:acme_default).domains.build(name: "").valid?
  end

  test "verifies? matches verified domains and their subdomains only" do
    project = projects(:acme_default)

    assert Domain.verifies?(project, "hello@acme.com")
    assert Domain.verifies?(project, "no-reply@mail.acme.com")
    assert_not Domain.verifies?(project, "hello@staging-acme.io"), "pending domains must not verify"
    assert_not Domain.verifies?(project, "hello@acme.com.evil.io"), "suffix must match on label boundary"
    assert_not Domain.verifies?(project, "hello@globex.com"), "other tenants' domains must not verify"
    assert_not Domain.verifies?(project, "not-an-address")
    assert_not Domain.verifies?(project, nil)
  end

  test "provision creates the SES identity and stores DKIM tokens" do
    domain = domain_with_client
    domain.ses_client.stub_responses(:create_email_identity,
      dkim_attributes: { tokens: %w[ tok1 tok2 tok3 ] })

    assert domain.provision
    assert_equal %w[ tok1 tok2 tok3 ], domain.dkim_tokens
    assert domain.pending?
  end

  test "provision falls back to check when the identity already exists" do
    domain = domain_with_client
    domain.ses_client.stub_responses(:create_email_identity, "AlreadyExistsException")
    domain.ses_client.stub_responses(:get_email_identity,
      verified_for_sending_status: true, dkim_attributes: { tokens: %w[ tok1 ] })

    assert domain.provision
    assert domain.verified?
  end

  test "provision marks the domain failed on SES errors" do
    domain = domain_with_client
    domain.ses_client.stub_responses(:create_email_identity, "TooManyRequestsException")

    assert_not domain.provision
    assert domain.failed?
  end

  test "check verifies, keeps pending, or fails by SES status" do
    domain = domain_with_client

    domain.ses_client.stub_responses(:get_email_identity,
      verified_for_sending_status: false, dkim_attributes: { tokens: %w[ tok1 ] })
    assert_not domain.check
    assert domain.pending?
    assert domain.last_checked_at.present?

    domain.ses_client.stub_responses(:get_email_identity,
      verified_for_sending_status: true, dkim_attributes: { tokens: %w[ tok1 ] })
    assert domain.check
    assert domain.verified?

    domain.ses_client.stub_responses(:get_email_identity, "NotFoundException")
    assert_not domain.check
    assert domain.failed?
  end

  test "dkim_records builds the CNAME pairs" do
    records = domains(:acme_com).dkim_records

    assert_equal 3, records.size
    assert_equal "acmetok1._domainkey.acme.com", records.first[:name]
    assert_equal "acmetok1.dkim.amazonses.com", records.first[:value]
  end

  test "decommission destroys the record even when SES deletion fails" do
    domain = domain_with_client
    domain.ses_client.stub_responses(:delete_email_identity, "NotFoundException")

    domain.decommission
    assert_not Domain.exists?(domain.id)
  end

  private
    def domain_with_client
      domain = projects(:acme_default).domains.create!(name: "mail.acme.com")
      domain.ses_client = Aws::SESV2::Client.new(stub_responses: true)
      domain
    end
end

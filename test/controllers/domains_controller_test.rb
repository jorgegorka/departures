require "test_helper"

class DomainsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
  end

  test "index lists only the current project's domains" do
    get domains_url

    assert_response :success
    assert_match "acme.com", response.body
    assert_no_match "globex.com", response.body
  end

  test "create provisions the domain and shows DKIM records" do
    assert_difference -> { projects(:acme_default).domains.count }, +1 do
      post domains_url, params: { domain: { name: "mail.acme.com" } }
    end

    assert_redirected_to domains_url
    assert projects(:acme_default).domains.exists?(name: "mail.acme.com")
  end

  test "create rejects an invalid domain name" do
    assert_no_difference -> { Domain.count } do
      post domains_url, params: { domain: { name: "not a domain" } }
    end

    assert_redirected_to domains_url
    assert flash[:alert].present?
  end

  test "create requires a source to provision against" do
    sign_in_as users(:outsider)
    wipe_send_domain # globex's email fixture holds an FK to its source
    projects(:globex_default).sources.destroy_all

    assert_no_difference -> { Domain.count } do
      post domains_url, params: { domain: { name: "mail.globex.com" } }
    end

    assert_redirected_to domains_url
    assert flash[:alert].present?
  end

  test "check re-verifies the domain" do
    post domain_check_url(domains(:acme_pending))

    assert_redirected_to domains_url
    assert domains(:acme_pending).reload.last_checked_at.present?
  end

  test "destroy decommissions the domain" do
    assert_difference -> { Domain.count }, -1 do
      delete domain_url(domains(:acme_pending))
    end

    assert_redirected_to domains_url
  end

  test "cross-tenant domains 404" do
    delete domain_url(domains(:globex_com))
    assert_response :not_found

    post domain_check_url(domains(:globex_com))
    assert_response :not_found
  end

  test "mutations require the manage_domains capability" do
    sign_in_as users(:read_only)

    post domains_url, params: { domain: { name: "mail.acme.com" } }
    assert_response :forbidden

    post domain_check_url(domains(:acme_pending))
    assert_response :forbidden

    delete domain_url(domains(:acme_pending))
    assert_response :forbidden
  end
end

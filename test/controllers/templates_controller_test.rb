require "test_helper"

class TemplatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
  end

  test "index lists only the current project's templates" do
    get templates_url

    assert_response :success
    assert_match "welcome", response.body
    assert_no_match "receipt", response.body
  end

  test "create adds a template" do
    assert_difference -> { projects(:acme_default).templates.count }, +1 do
      post templates_url, params: { template: { name: "Reset password", slug: "reset-password",
        subject: "Reset your password", text_body: "Click: {{ url }}" } }
    end

    assert_redirected_to templates_url
  end

  test "create re-renders on validation errors" do
    post templates_url, params: { template: { name: "", slug: "bad slug!" } }

    assert_response :unprocessable_entity
  end

  test "update edits a template" do
    patch template_url(templates(:acme_welcome)), params: { template: { subject: "Hello {{ name }}" } }

    assert_redirected_to templates_url
    assert_equal "Hello {{ name }}", templates(:acme_welcome).reload.subject
  end

  test "destroy removes a template" do
    assert_difference -> { Template.count }, -1 do
      delete template_url(templates(:acme_welcome))
    end
  end

  test "cross-tenant templates 404" do
    patch template_url(templates(:globex_receipt)), params: { template: { name: "X" } }
    assert_response :not_found
  end

  test "mutations require the manage_templates capability" do
    sign_in_as users(:sender)

    post templates_url, params: { template: { name: "X", slug: "x", text_body: "x" } }
    assert_response :forbidden
  end
end

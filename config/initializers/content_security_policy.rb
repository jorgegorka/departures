# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy.
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header

# Global policy for the dashboard. The email preview endpoint sets its own
# stricter per-response header (EmailsController::PREVIEW_CSP); the CSP
# middleware leaves responses that already carry the header untouched.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src  :self
    policy.style_src   :self
    policy.img_src     :self, :data
    policy.font_src    :self
    policy.connect_src :self
    policy.frame_src   :self
    policy.object_src  :none
    policy.frame_ancestors :none
    policy.base_uri    :self
    policy.form_action :self
  end

  # Nonces for the importmap inline tags and Turbo's injected progress-bar
  # style (Turbo picks the nonce up from csp_meta_tag in the layout).
  config.content_security_policy_nonce_generator = ->(request) do
    request.session.id.to_s.presence || SecureRandom.base64(16)
  end
  config.content_security_policy_nonce_directives = %w[script-src style-src]
end

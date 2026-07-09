class Template < ApplicationRecord
  VARIABLE_PATTERN = /\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/
  SLUG_FORMAT = /\A[a-z0-9]+(-[a-z0-9]+)*\z/

  Rendered = Data.define(:subject, :html, :text)

  belongs_to :project
  belongs_to :workspace, default: -> { project.workspace }

  normalizes :slug, with: ->(slug) { slug.strip.downcase }

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: { scope: :project_id },
    format: { with: SLUG_FORMAT, message: "may only contain lowercase letters, numbers, and dashes" }
  validate :validate_body_presence

  def render(variables = {})
    Rendered.new(subject: substitute(subject, variables, escape: false),
      html: substitute(html_body, variables, escape: true),
      text: substitute(text_body, variables, escape: false))
  end

  private
    def validate_body_presence
      if html_body.blank? && text_body.blank?
        errors.add(:base, "an html or text body is required")
      end
    end

    def substitute(content, variables, escape:)
      if content.blank?
        content
      else
        content.gsub(VARIABLE_PATTERN) do
          value = variables[Regexp.last_match(1)].to_s
          escape ? ERB::Util.html_escape(value) : value
        end
      end
    end
end

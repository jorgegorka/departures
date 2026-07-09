class WebhookLog < ApplicationRecord
  belongs_to :source
  belongs_to :workspace, default: -> { source.workspace }

  enum :status, %w[ received processed unmatched failed ].index_by(&:itself),
    default: "received", validate: true
end

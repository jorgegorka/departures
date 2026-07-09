class WebhookEndpoint < ApplicationRecord
  EVENT_TYPES = %w[ send delivery open click bounce complaint delivery_delay
                    reject rendering_failure subscription ].freeze

  belongs_to :project
  belongs_to :workspace, default: -> { project.workspace }

  has_many :deliveries, class_name: "WebhookDelivery", dependent: :destroy

  encrypts :secret

  scope :active, -> { where(active: true) }

  validates :url, presence: true, format: { with: %r{\Ahttps://}, message: "must be an https URL" }
  validate :validate_events

  before_create :assign_secret

  def events=(value)
    super(Array(value).map(&:to_s).reject(&:blank?))
  end

  def subscribed_to?(event_type)
    events.include?(event_type.to_s)
  end

  def success_rate
    settled = deliveries.where.not(status: "pending").count

    if settled.zero?
      nil
    else
      (deliveries.succeeded.count * 100.0 / settled).round(1)
    end
  end

  private
    def validate_events
      if events.blank?
        errors.add(:events, "must include at least one event type")
      elsif (events - EVENT_TYPES).any?
        errors.add(:events, "contains unknown event types: #{(events - EVENT_TYPES).join(", ")}")
      end
    end

    def assign_secret
      self.secret ||= "whsec_#{SecureRandom.alphanumeric(32)}"
    end
end

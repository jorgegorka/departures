class Email < ApplicationRecord
  include Statuses, Deliverable, Resendable, Broadcastable

  belongs_to :project
  belongs_to :workspace, default: -> { project.workspace }
  belongs_to :source
  belongs_to :api_key, optional: true

  has_many :recipients, class_name: "EmailRecipient", dependent: :destroy
  has_many :attachments, class_name: "EmailAttachment", dependent: :destroy
  has_many :idempotency_keys, dependent: :destroy
  has_many :events, class_name: "EmailEvent", dependent: :destroy

  validates :from, presence: true

  TIME_RANGES = { "1h" => 1.hour, "24h" => 24.hours, "7d" => 7.days, "30d" => 30.days }.freeze

  scope :hard_bounced, -> { bounced.where(bounce_type: "permanent") }
  scope :soft_bounced, -> { bounced.where(bounce_type: "transient") }

  scope :chronologically,         -> { order(created_at: :asc,  id: :asc)  }
  scope :reverse_chronologically, -> { order(created_at: :desc, id: :desc) }

  scope :indexed_by, ->(index) do
    case index
    when "queued"       then queued
    when "sending"      then sending
    when "sent"         then sent
    when "delivered"    then delivered
    when "opened"       then opened
    when "clicked"      then clicked
    when "bounced"      then bounced
    when "hard_bounces" then hard_bounced
    when "soft_bounces" then soft_bounced
    when "complained"   then complained
    when "failed"       then failed
    else all
    end
  end

  scope :sorted_by, ->(sort) do
    case sort
    when "oldest" then chronologically
    else reverse_chronologically
    end
  end

  scope :in_time_range, ->(param) do
    if (window = TIME_RANGES[param])
      where(created_at: window.ago..)
    else
      all
    end
  end

  scope :search, ->(query) do
    if query.present?
      like = "%#{sanitize_sql_like(query)}%"
      recipient_match = EmailRecipient.where("address LIKE :q ESCAPE '\\'", q: like).select(:email_id)
      where(<<~SQL, q: like).or(where(id: recipient_match))
        subject LIKE :q ESCAPE '\\' OR public_id LIKE :q ESCAPE '\\' OR "from" LIKE :q ESCAPE '\\'
      SQL
    else
      all
    end
  end

  scope :preloaded, -> { preload(:recipients, :events, :source) }

  before_create :assign_public_id

  def self.to_csv
    CSV.generate(headers: true) do |csv|
      csv << %w[ public_id status from subject bounce_type recipients created_at ]
      preloaded.find_each do |email|
        csv << [ email.public_id, email.status, email.from, email.subject, email.bounce_type,
          email.recipients.map(&:address).join(" "), email.created_at.iso8601 ]
      end
    end
  end

  def to_param
    public_id
  end

  private
    def assign_public_id
      self.public_id ||= "em_#{SecureRandom.alphanumeric(24)}"
    end
end

class Email < ApplicationRecord
  include Statuses, Deliverable, Resendable, Broadcastable
  include Chronological, TimeRangeFilterable, CsvExportable

  belongs_to :project
  belongs_to :workspace, default: -> { project.workspace }
  belongs_to :source
  belongs_to :api_key, optional: true

  has_many :recipients, class_name: "EmailRecipient", dependent: :destroy
  has_many :attachments, class_name: "EmailAttachment", dependent: :destroy
  has_many :idempotency_keys, dependent: :destroy
  has_many :events, class_name: "EmailEvent", dependent: :destroy

  validates :from, presence: true

  scope :hard_bounced, -> { bounced.where(bounce_type: "permanent") }
  scope :soft_bounced, -> { bounced.where(bounce_type: "transient") }

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

  scope :retention_expired_for, ->(source) do
    where(source: source, created_at: ...source.retention_days.days.ago).where.not(status: %w[ queued sending ])
  end

  before_create :assign_public_id

  def self.to_csv
    CSV.generate(headers: true) do |csv|
      csv << %w[ public_id status from subject bounce_type recipients created_at ]
      preloaded.find_each do |email|
        csv << [ email.public_id, email.status, csv_safe(email.from), csv_safe(email.subject), email.bounce_type,
          csv_safe(email.recipients.map(&:address).join(" ")), email.created_at.iso8601 ]
      end
    end
  end

  # Destroys per record (not delete_all) so dependent rows cascade and the
  # archived .eml comes off disk; small batches keep SQLite write locks short.
  def self.prune_expired
    Source.find_each do |source|
      retention_expired_for(source).in_batches(of: 100) do |batch|
        batch.each do |email|
          Email::MimeStore.delete(email)
          email.destroy
        end
      end
    end
  end

  def to_param
    public_id
  end

  def addresses_by_kind
    { to: recipients.kind_to.pluck(:address),
      cc: recipients.kind_cc.pluck(:address),
      bcc: recipients.kind_bcc.pluck(:address) }
  end

  private
    def assign_public_id
      self.public_id ||= "em_#{SecureRandom.alphanumeric(24)}"
    end
end

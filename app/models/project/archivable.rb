module Project::Archivable
  extend ActiveSupport::Concern

  included do
    scope :active, -> { where(archived_at: nil) }
    scope :archived, -> { where.not(archived_at: nil) }
  end

  def archived?
    archived_at.present?
  end

  def active?
    !archived?
  end

  def archive
    unless archived?
      update! archived_at: Time.current
    end
  end

  def unarchive
    if archived?
      update! archived_at: nil
    end
  end
end

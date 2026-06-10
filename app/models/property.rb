# One search target on the IGR portal, identified by a
# (year, district, tahsil, village, property_no) tuple. The scraper claims
# pending rows, runs the captcha/search loop, and records the outcome.
#
# Mumbai-tab searches leave +tahsil+ blank; everything else is reached through
# the Rest-of-Maharashtra form (District -> Tahsil -> Village cascade), which is
# why +tahsil+ is part of the unique search key.
class Property < ApplicationRecord
  has_many :documents, dependent: :destroy

  # pending  -> queued, not started
  # scraping -> a worker is actively scraping it right now (in progress)
  # found    -> scraped, documents retrieved
  # empty    -> ran fine, the site has no records for it
  # error    -> the scrape raised (failed)
  enum :search_status,
       { pending: "pending", scraping: "scraping", found: "found", empty: "empty", error: "error" },
       default: "pending"

  validates :year, :district, :village, :property_no, presence: true
  validates :year, numericality: { only_integer: true, greater_than: 2000 }
  validates :property_no,
            uniqueness: { scope: %i[year district tahsil village],
                          message: "is already queued for this village/year" }

  # Rows the scraper is allowed to (re)attempt.
  scope :scrapable,  -> { where(search_status: %w[pending error]) }
  scope :active,     -> { where(search_status: %w[pending scraping]) }
  scope :finished,   -> { where(search_status: %w[found empty error]) }
  scope :for_village, ->(v) { where(village: v) }

  def mumbai?
    tahsil.blank?
  end

  # Human-readable identifier used in logs and the admin views.
  def label
    parts = [village]
    parts << "Tahsil: #{tahsil}" if tahsil.present?
    parts << district
    "#{parts.join(' / ')} ##{property_no} (#{year})"
  end

  # Mark that a worker has started scraping this property (in progress).
  def mark_scraping!
    update!(search_status: "scraping", error_message: nil)
  end

  # Record a terminal outcome for this search attempt.
  def mark!(status, error: nil)
    update!(search_status: status, scraped_at: Time.current, error_message: error)
  end
end

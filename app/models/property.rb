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
  # parked   -> intentionally taken out of the work-list by the dashboard's
  #             "Stop & clear" button. Excluded from +due+ and +active+ (so it
  #             drops off the scrape-activity list) and never auto-resumed — a
  #             parked target only re-enters the queue when re-seeded (search form
  #             / rake task). search_status is a plain string column, so adding
  #             this value needs NO migration.
  enum :search_status,
       { pending: "pending", scraping: "scraping", found: "found", empty: "empty", error: "error",
         parked: "parked" },
       default: "pending"

  # --- Retry scheduling (unattended recovery from the flaky portal) ----------
  # A failed property is parked with a +next_retry_at+ and re-attempted once it
  # comes due. Backoff is exponential with jitter so a property that keeps
  # failing is tried less and less often instead of hammering the site.
  MAX_ATTEMPTS  = 8           # real (non-outage) failures before we give up
  RETRY_BASE    = 2.minutes   # first backoff window
  RETRY_CAP     = 30.minutes  # longest backoff window
  ENQUEUE_LEASE = 30.minutes  # don't re-pick a property while a job holds it

  validates :year, :district, :village, :property_no, presence: true
  validates :year, numericality: { only_integer: true, greater_than: 2000 }
  validates :property_no,
            uniqueness: { scope: %i[year district tahsil village],
                          message: "is already queued for this village/year" }

  # Found but cut short (throttle / next page wouldn't load) — has data, but more
  # remains, so it should be re-scraped to finish.
  scope :incomplete, -> { where(fully_scraped: false) }

  # Rows the scraper is allowed to (re)attempt: never-done (pending/error) plus
  # found-but-incomplete, so a throttled partial scrape gets finished next run.
  scope :scrapable,  -> { where(search_status: %w[pending error]).or(incomplete) }
  scope :active,     -> { where(search_status: %w[pending scraping]) }
  scope :finished,   -> { where(search_status: %w[found empty error]) }
  scope :for_village, ->(v) { where(village: v) }

  # Given up on: a real (non-outage) failure that exhausted MAX_ATTEMPTS. These
  # are excluded from +due+ and need a manual `rake igr:retry_dead` to revive.
  scope :dead, -> { where(search_status: "error").where(arel_table[:attempts].gteq(MAX_ATTEMPTS)) }

  # Accepted as best-effort: a found-but-incomplete plot that exhausted its resume
  # budget (the throttled portal kept cutting it short). Kept as :found with its
  # partial documents; dropped from +due+ so it isn't re-scraped forever. Revive
  # with `rake igr:retry_incomplete`.
  scope :incomplete_exhausted,
        -> { incomplete.where(arel_table[:attempts].gteq(MAX_ATTEMPTS)) }

  # The work-list the dispatcher feeds to the worker: anything not finished-good
  # (pending, retryable error, or found-but-incomplete) that isn't already in
  # flight (scraping), hasn't exhausted its attempts, and whose backoff window
  # has elapsed (next_retry_at NULL or in the past). Oldest-due first.
  scope :due, -> {
    scrapable
      .where.not(search_status: "scraping")
      .where(arel_table[:attempts].lt(MAX_ATTEMPTS))
      .where(arel_table[:next_retry_at].eq(nil).or(arel_table[:next_retry_at].lteq(Time.current)))
      .order(Arel.sql("next_retry_at IS NULL DESC"), :next_retry_at, :property_no)
  }

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

  # The dispatcher claims a property before enqueuing its job, pushing
  # +next_retry_at+ out by ENQUEUE_LEASE so it isn't handed out twice. If the
  # job runs it overwrites the lease (success clears the row from +due+; failure
  # sets a real backoff); if the worker died, the lease lapses and it comes due
  # again on its own.
  def lease!
    update!(enqueued_at: Time.current, next_retry_at: Time.current + ENQUEUE_LEASE)
  end

  # Park a failed property for a later retry with exponential backoff + jitter.
  # +kind+ is :outage (site down — don't count it) or :app (specific to this
  # property — count it toward MAX_ATTEMPTS and give up once exhausted).
  def schedule_retry!(kind:, error: nil)
    burn = kind == :app
    new_attempts = attempts + (burn ? 1 : 0)

    if burn && new_attempts >= MAX_ATTEMPTS
      # Out of retries: leave it :error, no next_retry_at — it drops out of +due+
      # until manually revived.
      update!(search_status: "error", attempts: new_attempts,
              last_error_kind: kind.to_s, error_message: error, next_retry_at: nil)
      return
    end

    update!(attempts: new_attempts, last_error_kind: kind.to_s,
            error_message: error, next_retry_at: Time.current + backoff_delay(new_attempts))
  end

  # A scrape COMPLETED but the property is still incomplete — the throttled portal
  # cut the page-walk or IndexII enrichment short. Count the resume pass against
  # the same +attempts+/MAX_ATTEMPTS budget as hard-error retries, with the same
  # exponential backoff, so a plot that can never be finished isn't re-scraped
  # forever. Once +attempts+ reaches MAX_ATTEMPTS it falls out of +due+ on its own
  # (the existing attempts gate) and keeps its partial data as best-effort — still
  # :found, documents still visible. Revive with `rake igr:retry_incomplete`.
  #
  # Sets attributes in memory only; the caller's +mark!(:found)+ persists them.
  def record_incomplete_pass!
    self.attempts        = attempts + 1
    self.last_error_kind = "incomplete"
    self.next_retry_at   = attempts >= MAX_ATTEMPTS ? nil : Time.current + backoff_delay(attempts)
  end

  private

  def backoff_delay(attempt)
    window = [RETRY_BASE * (2**[attempt - 1, 0].max), RETRY_CAP].min
    window + rand(0..(window * 0.25)) # jitter so failures don't sync up
  end
end

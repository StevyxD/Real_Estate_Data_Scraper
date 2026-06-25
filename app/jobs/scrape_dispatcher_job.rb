# The heartbeat that makes the scraper run unattended. Scheduled every minute
# (config/recurring.yml), it tops up the :scraping queue with whatever Property
# rows are currently +due+ — so failed targets that have served their backoff
# get retried automatically, with no manual `rake igr:scrape_pending`.
#
# It runs on the :default queue (a SEPARATE, non-browser worker) so it never
# competes with the single headless-Chrome worker on :scraping.
#
# Outage handling: when the portal goes down every scrape fails, which would
# otherwise burn through all targets. The dispatcher detects a run of
# outage-classed failures, then GATES on a cheap HTTP health probe — holding off
# (enqueuing nothing) until the site answers again, instead of feeding Chrome
# into a dead portal.
class ScrapeDispatcherJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError

  # Keep at most this many scrape jobs in flight. The browser handles one
  # property (often thousands of documents) at a time, so a shallow queue is
  # plenty and keeps leases from going stale while work waits.
  TARGET_INFLIGHT = 3
  # This many most-recent finished attempts all being outage-errors ⇒ suspect
  # the portal is down and switch to health-probe gating.
  OUTAGE_WINDOW = 4

  def perform
    return if Igr::ScrapeControl.paused? # user paused scraping from the dashboard
    return if paused_for_outage?

    slots = TARGET_INFLIGHT - inflight_count
    return if slots <= 0

    dispatched = 0
    Property.due.limit(slots).each do |property|
      property.lease!
      ScrapePropertyJob.perform_later(property.id)
      dispatched += 1
    end
    Rails.logger.info("[igr] dispatcher: enqueued #{dispatched} due propert#{dispatched == 1 ? 'y' : 'ies'}") if dispatched.positive?
  end

  # Number of scrape jobs genuinely queued or running right now. Counts ONLY
  # ready (waiting to run) + claimed (running) executions — NOT failed/blocked
  # jobs, which keep finished_at NULL forever and would otherwise be mistaken for
  # "in flight" and wedge the dispatcher (slots = TARGET_INFLIGHT - inflight ≤ 0,
  # so it stops enqueuing). A stale pile of failed jobs must never stall new work.
  def inflight_count
    job_ids = SolidQueue::Job.where(queue_name: "scraping").select(:id)
    SolidQueue::ReadyExecution.where(job_id: job_ids).count +
      SolidQueue::ClaimedExecution.where(job_id: job_ids).count
  end

  # DB-derived "is the portal down?" — true when the last OUTAGE_WINDOW finished
  # attempts were ALL outage-classed errors. Cheap; no network call. Used by
  # tests and as the trigger for the health probe below.
  def self.site_down?
    recent = Property.finished.where.not(scraped_at: nil)
                     .order(scraped_at: :desc).limit(OUTAGE_WINDOW)
                     .pluck(:search_status, :last_error_kind)
    recent.size >= OUTAGE_WINDOW &&
      recent.all? { |status, kind| status == "error" && kind == "outage" }
  end

  private

  # When outage is suspected, probe the portal: resume only once it answers.
  def paused_for_outage?
    return false unless self.class.site_down?

    if Igr::SiteHealth.up?
      Rails.logger.info("[igr] dispatcher: portal reachable again — resuming")
      false
    else
      Rails.logger.warn("[igr] dispatcher: portal still unreachable — holding off this cycle")
      true
    end
  end
end

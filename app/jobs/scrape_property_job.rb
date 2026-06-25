# Scrapes one Property on the :scraping queue. The queue is configured with a
# SINGLE worker thread (config/queue.yml) so only one headless Chrome runs at a
# time — running a second browser (or a `rails runner`) during a live scrape
# causes memory contention and InvalidSessionId crashes.
#
# Retries are NOT left to Solid Queue: a failed scrape is classified (site
# outage vs. property-specific) and parked with an exponential backoff via
# Property#schedule_retry!, then re-enqueued by ScrapeDispatcherJob once it comes
# due. So this job swallows scrape errors (records them on the Property) rather
# than raising — a raise would spin up Solid Queue's own retry/failed-job path
# and double up with ours.
class ScrapePropertyJob < ApplicationJob
  queue_as :scraping

  discard_on ActiveJob::DeserializationError

  def perform(property_id, enrich: true)
    property = Property.find(property_id)
    Igr::PropertyScraper.call(property, enrich:)
  rescue StandardError => e
    # PropertyScraper has already recorded the run's status (:found if we kept
    # partial docs, :error otherwise). Layer the retry schedule on top.
    kind = Igr::ErrorClassifier.kind(e)
    property&.schedule_retry!(kind:, error: "#{e.class}: #{e.message}")
    Rails.logger.warn("[igr] #{property&.label}: #{kind} failure, parked for retry " \
                      "(attempt #{property&.attempts}/#{Property::MAX_ATTEMPTS}): #{e.class}")
  end
end

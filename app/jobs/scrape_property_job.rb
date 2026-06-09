# Scrapes one Property on the :scraping queue. The queue is configured with a
# SINGLE worker thread (config/queue.yml) so only one headless Chrome runs at a
# time — running a second browser (or a `rails runner`) during a live scrape
# causes memory contention and InvalidSessionId crashes.
class ScrapePropertyJob < ApplicationJob
  queue_as :scraping

  # Don't auto-retry browser crashes forever; the property is marked :error and
  # can be re-enqueued with `rake igr:scrape_pending`.
  discard_on ActiveJob::DeserializationError

  def perform(property_id, enrich: true)
    property = Property.find(property_id)
    Igr::PropertyScraper.call(property, enrich:)
  end
end

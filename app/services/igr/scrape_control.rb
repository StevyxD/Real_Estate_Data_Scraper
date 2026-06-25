module Igr
  # Pause / resume the scraper from the UI. Built on Solid Queue's native queue
  # pausing: pausing the :scraping queue makes the browser worker STOP claiming
  # new scrape jobs (the one already running finishes — we never hard-kill a live
  # Chrome, which the project warns is crash-prone). The dispatcher also checks
  # +paused?+ and stops enqueuing while paused, so nothing piles up. Resuming lets
  # the worker claim again and the dispatcher refill — work continues exactly
  # where it left off (incomplete plots resume per the normal retry path).
  #
  # State lives in Solid Queue's own +solid_queue_pauses+ table (the DB), so it is
  # shared across the separate worker / dispatcher / web processes — unlike the
  # per-process memory cache.
  module ScrapeControl
    QUEUE = "scraping".freeze

    module_function

    def paused?
      SolidQueue::Pause.exists?(queue_name: QUEUE)
    end

    def pause!
      SolidQueue::Queue.new(QUEUE).pause
    end

    def resume!
      SolidQueue::Queue.new(QUEUE).resume
    end
  end
end

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

    # Panic button behind the dashboard's "Stop & clear". Brings the scraper to a
    # full idle in one shot:
    #   1. pause the queue (worker stops claiming, dispatcher stops enqueuing),
    #   2. delete every queued-but-not-started scrape job, and
    #   3. PARK all pending/scraping targets so the activity list empties and they
    #      won't auto-resume.
    # The one plot already mid-scrape (a CLAIMED job) is left to finish on its own
    # — a clean drain; we never hard-kill a live Chrome. Re-seeding a search (form
    # or rake) revives parked targets to pending AND resumes the queue, so the user
    # doesn't have to remember to hit Resume. Returns counts for the flash message.
    def stop_and_clear!
      pause!
      cleared = clear_queue
      parked  = Property.where(search_status: %w[pending scraping])
                        .update_all(search_status: "parked", next_retry_at: nil, enqueued_at: nil)
      { cleared:, parked: }
    end

    # Delete queued (ready) scrape jobs and their job rows. CLAIMED executions (the
    # one running in Chrome) are deliberately untouched so the in-flight plot
    # finishes cleanly; failed/blocked jobs are history, not "activity", so they're
    # left alone too.
    def clear_queue
      job_ids = SolidQueue::Job.where(queue_name: QUEUE, finished_at: nil).select(:id)
      ready   = SolidQueue::ReadyExecution.where(job_id: job_ids)
      ready_job_ids = ready.pluck(:job_id)
      ready.delete_all
      SolidQueue::Job.where(id: ready_job_ids).delete_all
      ready_job_ids.size
    end
  end
end

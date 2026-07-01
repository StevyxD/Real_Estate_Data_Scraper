# Pause / resume the scraper from the dashboard. Pausing stops the worker from
# claiming new scrape jobs (the in-flight plot finishes); resuming lets it
# continue from where it left off.
class ScrapeControlsController < ApplicationController
  def pause
    Igr::ScrapeControl.pause!
    redirect_to dashboard_path,
                notice: "Scraping paused. The current plot will finish; no new ones start until you resume."
  end

  def resume
    Igr::ScrapeControl.resume!
    redirect_to dashboard_path, notice: "Scraping resumed."
  end

  # Hard stop: pause, drain the queue, and park every pending target so the
  # scraper goes fully idle. The plot currently scraping finishes on its own;
  # re-seed a search to start again.
  def stop
    result = Igr::ScrapeControl.stop_and_clear!
    redirect_to dashboard_path,
                notice: "Scraping stopped. Cleared #{result[:cleared]} queued job(s) and parked " \
                        "#{result[:parked]} target(s). Any plot mid-scrape will finish; re-seed a " \
                        "search to start again."
  end
end

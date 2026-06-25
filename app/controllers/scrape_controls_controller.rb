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
end

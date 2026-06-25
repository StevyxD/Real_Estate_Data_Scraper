class DashboardController < ApplicationController
  STATUS_ORDER = %w[scraping pending found empty error].freeze

  def index
    @paused = Igr::ScrapeControl.paused?
    @counts = Property.group(:search_status).count

    # In-flight: actively scraping first, then queued.
    @active = Property.active
                      .select("properties.*, (SELECT COUNT(*) FROM documents WHERE documents.property_id = properties.id) AS docs_count")
                      .order(Arel.sql("CASE search_status WHEN 'scraping' THEN 0 ELSE 1 END"), updated_at: :desc)
                      .limit(30)

    # Recently finished searches (found / empty / error), newest first.
    @recent = Property.finished
                      .select("properties.*, (SELECT COUNT(*) FROM documents WHERE documents.property_id = properties.id) AS docs_count")
                      .order(scraped_at: :desc)
                      .limit(20)

    @recent_documents = Document.includes(:property).order(created_at: :desc).limit(8)

    # "Live" = something is actively scraping, or there's been queue activity in
    # the last couple of minutes (so idle, long-queued rows don't keep refreshing).
    @auto_refresh = Property.scraping.exists? ||
                    Property.active.where(updated_at: 2.minutes.ago..).exists?
  end
end

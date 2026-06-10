class DashboardController < ApplicationController
  STATUS_ORDER = %w[scraping pending found empty error].freeze

  def index
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

    # Keep refreshing while anything is queued or running.
    @auto_refresh = Property.active.exists?
  end
end

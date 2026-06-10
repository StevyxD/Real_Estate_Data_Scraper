module Igr
  # Orchestrates a full scrape for one Property: pick the right session by
  # Property#mumbai?, run the captcha/search loop, turn each grid row into a
  # Document, enrich it from its IndexII detail page (on the same open browser),
  # and record the outcome on the Property.
  class PropertyScraper
    def self.call(property, **opts)
      new(property, **opts).call
    end

    def initialize(property, logger: nil, headless: true, enrich: true)
      @property = property
      @logger   = logger || Rails.logger
      @headless = headless
      @enrich   = enrich
    end

    def call
      @property.mark_scraping! # in progress — visible on the dashboard

      session = session_for(@property)
      result  = session.run(@property)
      @property.captcha_attempts = result.attempts

      if result.status == :found
        persist(result.rows, session)
        @property.mark!(:found)
      else
        @property.mark!(:empty)
      end

      result
    rescue StandardError => e
      @logger.error("[igr] scrape failed for #{@property.label}: #{e.class}: #{e.message}")
      @property.mark!(:error, error: "#{e.class}: #{e.message}")
      raise
    ensure
      session&.close
    end

    private

    def session_for(property)
      klass = property.mumbai? ? Igr::MumbaiSession : Igr::RestMaharashtraSession
      klass.new(logger: @logger, headless: @headless)
    end

    def persist(rows, session)
      rows.each do |row|
        attrs = row.attrs.dup

        if @enrich && (index_ii = session.fetch_index_ii(row.row_index))
          attrs.merge!(index_ii.attrs) # IndexII is authoritative over the sparse grid
          attrs[:index_ii] = index_ii.sections
          attrs[:index_ii_fetched] = true
        end

        attrs[:raw] = row.raw
        upsert_document(attrs)
      end
    end

    # Idempotent: re-scraping a property updates the existing rows in place.
    def upsert_document(attrs)
      document = @property.documents.find_or_initialize_by(doc_number: attrs[:doc_number])
      document.assign_attributes(attrs)
      document.save!
      document
    end
  end
end

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
        scrape_all_documents(session, result.rows)
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

    # Two passes, deliberately decoupled so flaky IndexII detail pages can never
    # truncate the document LIST:
    #   Pass 1 — walk every page and save the grid rows, opening NO detail windows,
    #            so nothing can wedge the browser mid-walk (this captures all pages).
    #   Pass 2 — re-walk from page 1 and enrich each row's IndexII, best-effort: a
    #            failure leaves that doc with its grid data (index_ii_fetched=false),
    #            it never loses a document or stops the run.
    def scrape_all_documents(session, first_rows)
      page1_first = first_rows&.first&.attrs&.dig(:doc_number)

      session.each_result_page(first_rows) do |rows, _page|
        rows.each { |row| upsert_document(grid_attrs(row)) }
      end
      return unless @enrich

      unless session.reset_to_first_page(page1_first)
        @logger.warn("[igr] could not return to page 1 for #{@property.label} — " \
                     "IndexII enrichment skipped this run (resume will retry)")
        return
      end

      enriched = 0
      session.each_result_page do |rows, _page|
        rows.each { |row| enriched += 1 if enrich_document(session, row) }
      end
      @logger.info("[igr] enriched #{enriched} new document(s) for #{@property.label} " \
                   "(already-enriched rows skipped — resume)")
    end

    # Enrich one row's already-saved document with its IndexII detail. RESUMES: a
    # document that is already enriched is skipped WITHOUT re-fetching its detail
    # page — so re-running a property only does the IndexII work for new rows (the
    # expensive, hang-prone part), instead of redoing everything. Returns the
    # document when it enriched it, nil when it skipped or the fetch failed.
    def enrich_document(session, row)
      document = @property.documents.find_by(document_key(row.attrs))
      return if document.nil? || document.index_ii_fetched?

      index_ii = session.fetch_index_ii(row.row_index) or return
      document.update!(
        index_ii.attrs.merge(index_ii: index_ii.sections, index_ii_fetched: true)
      )
      document
    end

    # Grid-row attributes for the list pass, with a building name extracted from the
    # grid Property Description (the regex catches the well-formed ones; the rest are
    # left for the LLM backfill). IndexII enrichment may overwrite it later with a
    # detail-sourced name.
    def grid_attrs(row)
      attrs = row.attrs.merge(raw: row.raw)
      name = Igr::BuildingName.call(attrs[:property_description].to_s)
      attrs[:building_name] = name if name.present?
      attrs
    end

    # Idempotent: re-scraping a property updates the existing rows in place.
    def upsert_document(attrs)
      document = @property.documents.find_or_initialize_by(document_key(attrs))
      document.assign_attributes(attrs)
      document.save!
      document
    end

    # A registration is unique within a property by (doc_number, SRO office) — the
    # SAME doc number recurs across the 20+ sub-registrar offices a property search
    # spans, so keying on doc_number alone silently merges different registrations.
    def document_key(attrs)
      { doc_number: attrs[:doc_number], sro_code: attrs[:sro_code] }
    end
  end
end

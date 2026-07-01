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
      started = clock

      session = session_for(@property)
      result  = session.run(@property)
      @property.captcha_attempts = result.attempts
      @logger.info("[igr][timing] #{@property.label}: search → #{result.status} in " \
                   "#{elapsed(started)}s (#{result.attempts} captcha attempt(s))")

      if result.status == :found
        scrape_all_documents(session, result.rows)
        mark_found
      elsif @property.documents.exists?
        # The search came back empty, but we already hold documents from a prior
        # scrape. On this flaky portal an "empty" result is unreliable (a wrong
        # captcha or a throttled search returns the same blank grid as a genuine
        # "no records") — so it is almost certainly a transient miss, NOT proof the
        # records vanished. Do NOT downgrade to :empty and bury real data; keep it
        # :found and flag it incomplete so the retry path re-attempts it.
        @property.fully_scraped = false
        mark_found
      else
        @property.mark!(:empty)
      end

      result
    rescue StandardError => e
      @logger.error("[igr] scrape failed for #{@property.label}: #{e.class}: #{e.message}")
      # A retry that fails (e.g. the portal times out) must NOT bury documents we
      # already have behind an :error status — the UI only links :found properties
      # to their docs. Keep a property with data as :found (the resume pass can
      # finish it later); only mark :error when there is genuinely nothing to show.
      if @property.documents.exists?
        @property.fully_scraped = false # an error mid-scrape means it's not done
        @property.mark!(:found)
      else
        @property.mark!(:error, error: "#{e.class}: #{e.message}")
      end
      raise
    ensure
      session&.close
    end

    private

    # Persist a :found outcome. When the result is still incomplete (the throttled
    # portal cut the page-walk / enrichment short), count the resume pass against
    # the property's budget so the same plot can't be re-scraped forever — once it
    # exhausts the budget it drops out of the dispatcher's worklist and keeps its
    # partial data as best-effort. A genuinely complete scrape never counts a pass.
    def mark_found
      unless @property.fully_scraped
        @property.record_incomplete_pass!
        if @property.attempts >= Property::MAX_ATTEMPTS
          @logger.info("[igr] #{@property.label}: still incomplete after #{@property.attempts} " \
                       "resume passes — accepting as best-effort (won't re-queue)")
        end
      end
      @property.mark!(:found)
    end

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

      # :incomplete ⇒ the page-walk was cut short (throttle / next page wouldn't
      # load). Record it so the property is flagged and re-scraped, not mistaken
      # for fully captured.
      list_started = clock
      pages = 0
      list_status = session.each_result_page(first_rows) do |rows, _page|
        pages += 1
        rows.each { |row| upsert_document(grid_attrs(row)) }
      end
      @property.fully_scraped = (list_status != :incomplete)
      @logger.info("[igr][timing] #{@property.label}: page-walk #{pages} page(s), " \
                   "#{@property.documents.count} doc(s) in #{elapsed(list_started)}s " \
                   "(#{list_status})")

      return unless @enrich

      unless session.reset_to_first_page(page1_first)
        @logger.warn("[igr] could not return to page 1 for #{@property.label} — " \
                     "IndexII enrichment skipped this run (resume will retry)")
        # Enrichment never ran, so docs are still un-enriched — keep the property
        # due so the resume pass finishes them.
        @property.fully_scraped = false
        return
      end

      enrich_started = clock
      enriched = 0
      session.each_result_page do |rows, _page|
        rows.each { |row| enriched += 1 if enrich_document(session, row) }
      end
      @logger.info("[igr][timing] #{@property.label}: enriched #{enriched} new document(s) in " \
                   "#{elapsed(enrich_started)}s (already-enriched rows skipped — resume)")

      # Self-heal silent enrichment gaps: if ANY document still lacks its IndexII
      # detail (a fetch returned nil on the flaky portal, without raising), the
      # property is NOT fully done. Flag it incomplete so the dispatcher re-runs
      # it — the resume pass only re-fetches the un-enriched rows, not everything.
      unfetched = @property.documents.where(index_ii_fetched: false).count
      if unfetched.positive?
        @logger.info("[igr] #{@property.label}: #{unfetched} document(s) still un-enriched — " \
                     "flagging incomplete for resume")
        @property.fully_scraped = false
      end
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

    # Monotonic timing helpers for the [igr][timing] logs — wall-clock breakdown of
    # where a scrape spends its seconds (search vs page-walk vs IndexII enrichment),
    # so the slow part is measured, not guessed.
    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def elapsed(since) = (clock - since).round(1)
  end
end

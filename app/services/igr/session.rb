require "selenium-webdriver"

module Igr
  # Abstract base for an IGR search session. Owns the whole shared engine:
  # headless Chrome lifecycle, captcha capture/solve loop, the async results
  # grid, and the IndexII detail window. Subclasses (MumbaiSession,
  # RestMaharashtraSession) own ONLY the form-specific selectors and #fill_form.
  #
  # CRITICAL FLOW (the bug that made every scrape come back empty): fill the form
  # exactly ONCE, then loop solve->submit on the SAME page. Each submit is an
  # ASP.NET postback that regenerates the captcha while preserving the form via
  # ViewState. Re-filling or reloading the page between attempts corrupts the
  # form, so even a correct captcha then returns an empty grid.
  class Session
    BASE_URL = "https://freesearchigrservice.maharashtra.gov.in/".freeze

    EMPTY_CONFIRMATIONS = 5  # blank grids (with a valid-length guess) to trust :empty
    RESULT_TIMEOUT      = 12 # seconds to poll for the async grid postback
    PAGE_NAV_TIMEOUT    = 25 # seconds for a Page$N postback to re-render (portal is slow)
    PAGE_TIMEOUT        = 45
    INDEX_II_TIMEOUT    = 20 # cap a hung IndexII detail window (else the renderer hangs ~45s)
    MAX_PAGES           = 1000 # runaway guard — high enough for the largest properties (#3 ~200 pages)
    ELEMENT_TIMEOUT     = 120 # default element wait (2 min) — give the slow/throttled portal plenty of time
    OPEN_RETRIES        = 3  # reload the landing page this many times if its form won't appear
    OPEN_BACKOFF        = 6  # seconds × attempt to wait before each landing-page reload

    # The results GridView's UniqueID — stable across the site (it is also the
    # target of the IndexII postback). Used to fire Page$N directly, so pagination
    # never depends on first scraping the target out of a (slow-to-render) pager.
    GRID_TARGET = "RegistrationGrid"

    # The GridView page size. The last page holds the remainder, so any page with
    # fewer rows than this is necessarily the last one.
    PAGE_SIZE = 10

    Result = Struct.new(:status, :rows, :attempts, keyword_init: true)

    attr_reader :driver, :logger

    def initialize(logger: nil, headless: true)
      @logger   = logger || Rails.logger
      @headless = headless
    end

    # Run the search for one property and return a Result (:found / :empty).
    # The browser is left OPEN so the caller can drive IndexII enrichment on the
    # same results page; the caller MUST call #close afterwards (PropertyScraper
    # does this in an ensure block).
    def run(property, max_attempts: EMPTY_CONFIRMATIONS * 2)
      @property = property
      start_browser
      open_search
      fill_form(property) # subclass: fill the form ONCE
      solve_and_submit(max_attempts:)
    end

    # Convenience for callers that don't need IndexII enrichment.
    def scrape(property, **opts)
      run(property, **opts)
    ensure
      close
    end

    def close
      quit_browser
    end

    # Open the IndexII (सूची क्र.2) detail report for a data row and parse it.
    # The link opens a NEW window; __doPostBack via execute_script throws a
    # strict-mode "arguments" error, so we CLICK the anchor instead.
    def fetch_index_ii(row_index)
      main = driver.window_handle
      link = index_ii_link(row_index) or return nil

      link.click
      handle = wait_for_new_window(main) or return nil

      # Cap how long a wedged detail window can hang (default is ~45s of "renderer
      # not responding"); on these huge properties that adds up to many lost
      # minutes. The ensure restores it and always cleans the window up.
      driver.manage.timeouts.page_load = INDEX_II_TIMEOUT
      driver.switch_to.window(handle)
      Igr::IndexIiParser.parse(driver.page_source)
    rescue Selenium::WebDriver::Error::WebDriverError => e
      logger.warn("[igr] IndexII row #{row_index} failed: #{e.message.to_s.lines.first&.strip}")
      nil
    ensure
      return_to_results_window(main)
      restore_page_timeout
    end

    # Walk every page of the results grid for the current property, yielding the
    # parsed rows of each page (and its 1-based page number) with that page LIVE
    # in the DOM. Page 1 is the rows solve_and_submit already found (passed in, so
    # we do NOT re-parse and race the async render); pages 2..N are reached by
    # firing the GridView's Page$N postback.
    #
    # End-of-pages is decided robustly for the slow/throttled portal, without
    # trusting a single pager read (which truncated properties at page 1 when the
    # pager rendered late). We stop when EITHER the page is short (fewer than
    # PAGE_SIZE rows ⇒ the remainder page, always last) OR the pager is readable and
    # confidently shows no higher page. If the pager can't be read we do NOT assume
    # the end — we probe the next page and let navigation decide. The next-page
    # decision is made before the block runs (from the clean grid), and we recover
    # the results window after the block (closing any stray IndexII window) before
    # navigating.
    # Returns :complete when it reached the genuine last page, or :incomplete when
    # the walk was cut short — the next page was expected but would not load (the
    # throttled portal) or the MAX_PAGES guard was hit. The caller uses this to flag
    # a property for re-scraping instead of treating a truncated walk as done.
    def each_result_page(first_rows = nil)
      rows = first_rows.presence || Igr::ResultParser.parse(driver.page_source)
      return :complete if rows.blank?

      page = 1
      loop do
        logger.info("[igr] page #{page}: #{rows.size} rows")
        short_page = rows.size < PAGE_SIZE # the remainder page is always the last
        prev_first = rows.first.attrs[:doc_number]

        yield rows, page

        return :complete if short_page
        if page >= MAX_PAGES
          logger.warn("[igr] hit MAX_PAGES (#{MAX_PAGES}) — there may be more (incomplete)")
          return :incomplete
        end
        # A full page may have more after it. Only skip the next-page attempt when
        # the pager CONFIDENTLY says we're at the last page; if the pager can't be
        # read (slow/throttled portal), don't trust "no more" — try the next page
        # and let navigation decide. This stops a late-rendering pager truncating
        # a multi-page property at page 1.
        return :complete if pager_says_last_page?(page)

        recover_results_page # close stray IndexII windows the block may have left open
        rows = go_to_page(GRID_TARGET, page + 1, prev_first)
        if rows.blank? || rows.first.attrs[:doc_number] == prev_first
          logger.warn("[igr] page #{page + 1} would not load — stopping at page #{page} (INCOMPLETE)")
          return :incomplete
        end
        page += 1
      end
    end

    # Navigate the results grid back to page 1 for the enrichment re-walk, and
    # CONFIRM we landed there by matching page 1's known first DocNo. After the list
    # pass we sit on the last page; on the slow/throttled portal a single Page$1
    # postback can silently fail to advance, leaving us on the (short) last page —
    # which then makes the enrichment pass quit after one page. Retry until the
    # first DocNo matches +page1_first+. Returns true once confirmed (or for a
    # single-page result), false if it never got back — the caller then skips
    # enrichment and lets the resume pass retry next run.
    def reset_to_first_page(page1_first)
      return true if page1_first.nil?

      5.times do
        current = Igr::ResultParser.parse(driver.page_source).first&.attrs&.dig(:doc_number)
        return true if current == page1_first

        go_to_page(GRID_TARGET, 1, current)
      end
      Igr::ResultParser.parse(driver.page_source).first&.attrs&.dig(:doc_number) == page1_first
    end

    private

    # After a page's block (IndexII enrichment) we may be left on, or with, a stray
    # detail window — or a hung renderer left one open. Close every window except
    # the main results window and dismiss the popup, so the next Page$N postback
    # runs against a clean results grid.
    def recover_results_page
      handles = driver.window_handles
      if handles.size > 1
        main = handles.first
        (handles - [main]).each do |h|
          driver.switch_to.window(h)
          driver.close
        rescue Selenium::WebDriver::Error::WebDriverError
          next
        end
        driver.switch_to.window(driver.window_handles.first)
      end
      dismiss_popup
    rescue Selenium::WebDriver::Error::WebDriverError
      nil
    end

    # Close any IndexII detail window and return to the results window — runs in
    # fetch_index_ii's ensure, so even a hung/timed-out fetch leaves the browser on
    # the results grid for the next row/page.
    def return_to_results_window(main)
      (driver.window_handles - [main]).each do |handle|
        driver.switch_to.window(handle)
        driver.close
      rescue Selenium::WebDriver::Error::WebDriverError
        next
      end
      driver.switch_to.window(main)
      dismiss_popup
    rescue Selenium::WebDriver::Error::WebDriverError
      safe_switch(main)
    end

    def restore_page_timeout
      driver.manage.timeouts.page_load = PAGE_TIMEOUT
    rescue Selenium::WebDriver::Error::WebDriverError
      nil
    end

    # Is the pager READABLE and showing no page beyond +page+ (i.e. we are
    # confidently on the last page)? Only then do we skip trying the next page.
    # Retries because the pager can render a few seconds after the rows. Crucially,
    # if the pager never becomes readable within the budget we return FALSE — "not
    # sure", so the caller probes the next page rather than truncating. That probe
    # is the safety net for the slow/throttled portal where the pager lags.
    def pager_says_last_page?(page, tries: 14)
      tries.times do
        pages = Igr::ResultParser.pager_pages(driver.page_source)
        if pages.any?
          return false if pages.any? { |n| n > page } # more pages exist
          return true                                 # pager present, nothing higher
        end
        sleep 0.4
      end
      false # pager unreadable → don't trust it; let navigation decide
    end

    # Fire the GridView's Page$N postback and wait for the grid to re-render with
    # a new first row. Uses a setTimeout'd STRING so __doPostBack runs in global
    # non-strict scope (a direct call throws the strict-mode "arguments" error on
    # this site — same dodge as btnSearch_RestMaha). The caller has already
    # confirmed the page exists, so re-fire a few times: the portal is slow and a
    # single postback can be dropped or render past one wait window. Returns the
    # rows once the page advances, else the last parse.
    def go_to_page(target, number, prev_first, fires: 3)
      fires.times do
        driver.execute_script(%(setTimeout("__doPostBack('#{target}','Page$#{number}')", 0);))
        wait_idle

        deadline = monotonic + PAGE_NAV_TIMEOUT
        loop do
          dismiss_popup
          rows = Igr::ResultParser.parse(driver.page_source)
          return rows if rows.any? && rows.first.attrs[:doc_number] != prev_first
          break if monotonic > deadline

          sleep 0.5
        end
      end
      Igr::ResultParser.parse(driver.page_source)
    end

    # ---- subclass contract -------------------------------------------------
    def captcha_image_id = raise(NotImplementedError)
    def captcha_input_id = raise(NotImplementedError)
    def submit_button_id = raise(NotImplementedError)
    def open_tab         = raise(NotImplementedError) # reveal this tab's form
    def fill_form(_property) = raise(NotImplementedError)

    # ---- browser lifecycle -------------------------------------------------
    def start_browser
      options = Selenium::WebDriver::Chrome::Options.new
      options.add_argument("--headless=new") if @headless
      # Without this the headless tab crashes ("session deleted as the browser
      # has closed the connection") on the results page.
      options.add_argument("--disable-dev-shm-usage")
      options.add_argument("--no-sandbox")
      options.add_argument("--disable-gpu")
      options.add_argument("--window-size=1400,1800")

      @driver = Selenium::WebDriver.for(:chrome, options:)
      @driver.manage.timeouts.page_load = PAGE_TIMEOUT
      @driver
    end

    def quit_browser
      driver&.quit
    rescue Selenium::WebDriver::Error::WebDriverError
      nil
    ensure
      @driver = nil
    end

    # Load the landing page and reveal the search form, retrying the whole page
    # load a few times. On a slow/throttled portal the page often comes back
    # without the form (the tab button never appears → open_tab times out); a fresh
    # reload after a backoff usually gets a complete page. Only a persistent
    # failure across all retries propagates.
    def open_search
      attempt = 0
      begin
        driver.navigate.to(BASE_URL)
        dismiss_popup          # intro "Search Flow" popup overlays every load
        open_tab               # subclass: reveal the tab's form (raises if it won't appear)
        dismiss_popup
      rescue Selenium::WebDriver::Error::TimeoutError,
             Selenium::WebDriver::Error::NoSuchElementError => e
        attempt += 1
        raise if attempt >= OPEN_RETRIES

        logger.warn("[igr] landing page didn't load (#{e.class}); reloading #{attempt}/#{OPEN_RETRIES}")
        sleep(OPEN_BACKOFF * attempt)
        retry
      end
    end

    # ---- captcha + submit loop --------------------------------------------
    def solve_and_submit(max_attempts:)
      valid_empties = 0
      attempt = 0

      max_attempts.times do
        attempt += 1
        ensure_search_form # recover if the site bounced us to the landing page
        prepare_attempt    # subclass hook: re-assert wiped fields + refresh captcha
        guess = solve_captcha
        logger.info("[igr] attempt #{attempt}: captcha=#{guess.inspect}")

        submit_search(guess)
        rows = wait_for_results
        return Result.new(status: :found, rows:, attempts: attempt) if rows.any?

        valid_empties += 1 if Igr::Captcha.valid?(guess)
        return Result.new(status: :empty, rows: [], attempts: attempt) if valid_empties >= EMPTY_CONFIRMATIONS

        dismiss_popup # reappears after the postback
      end

      Result.new(status: :empty, rows: [], attempts: attempt)
    end

    # The site occasionally bounces back to the landing page after a submit
    # (losing the Mumbai form, so btnSearch/imgCaptcha disappear). When that
    # happens we MUST re-open and re-fill the form — but ONLY then; re-filling an
    # intact form corrupts its ViewState and makes correct captchas return empty.
    def ensure_search_form
      return if driver.find_elements(id: submit_button_id).any? &&
                driver.find_elements(id: captcha_image_id).any?

      logger.info("[igr] search form lost (bounced to landing) — reopening")
      open_search
      fill_form(@property)
    end

    # Hook run before each captcha solve+submit attempt. Default no-op (Mumbai);
    # RestMaharashtraSession uses it to re-assert the property number (wiped by the
    # dropdown-cascade postback) and force a fresh, in-sync captcha image.
    def prepare_attempt; end

    # Block until the ASP.NET AJAX UpdatePanel finishes its async postback, so a
    # still-in-flight cascade postback can't clobber fields we set next.
    def wait_idle(timeout: 15)
      wait(timeout:).until do
        driver.execute_script(
          "try { return !Sys.WebForms.PageRequestManager.getInstance().get_isInAsyncPostBack(); } " \
          "catch (e) { return true; }"
        )
      end
    rescue Selenium::WebDriver::Error::TimeoutError
      nil
    end

    def solve_captcha
      Igr::Captcha.solve(capture_captcha)
    end

    # element.screenshot_as(:png) is BLANK in headless; draw the same-origin
    # <img> onto a canvas and read toDataURL (not tainted) instead.
    def capture_captcha
      element = wait.until { driver.find_element(id: captcha_image_id) }
      driver.execute_script(<<~JS, element)
        const img = arguments[0];
        const canvas = document.createElement('canvas');
        canvas.width  = img.naturalWidth  || img.width;
        canvas.height = img.naturalHeight || img.height;
        canvas.getContext('2d').drawImage(img, 0, 0);
        return canvas.toDataURL('image/png');
      JS
    end

    def submit_search(guess)
      # Fill + click together under the retry: an in-flight postback can briefly
      # remove btnSearch from the DOM, so the click must retry on stale/missing too.
      with_retry do
        field = driver.find_element(id: captcha_input_id)
        field.clear
        field.send_keys(guess)
        js_click(driver.find_element(id: submit_button_id))
      end
    end

    # Poll for the async UpdatePanel postback. Both "wrong captcha" and "no
    # records" leave the grid empty with no message, so empty == no rows.
    def wait_for_results
      deadline = monotonic + RESULT_TIMEOUT
      loop do
        rows = Igr::ResultParser.parse(driver.page_source)
        return rows if rows.any?
        break if monotonic > deadline

        sleep 0.5
      end
      []
    end

    # The IndexII control is an <input type="button" value="IndexII"
    # onclick="__doPostBack('RegistrationGrid','indexII$<row_index>')"> in the
    # last cell — NOT an anchor. Clicking it opens the सूची क्र.2 report in a new
    # window (calling __doPostBack via execute_script throws a strict-mode error).
    def index_ii_link(row_index)
      rows = driver.find_elements(css: "#RegistrationGrid > tbody > tr")
      rows = driver.find_elements(css: "#RegistrationGrid tr") if rows.empty?
      tr = rows[row_index + 1] or return nil # row 0 is the header

      controls = tr.find_elements(css: "input[type='button'], a")
      controls.find { |c| index_ii_label?(c) } || controls.last
    end

    def index_ii_label?(control)
      [control.attribute("value"), control.text].any? { |t| t.to_s.strip.casecmp?("IndexII") }
    end

    # ---- helpers -----------------------------------------------------------
    def dismiss_popup
      driver.find_elements(css: "#popup a.btnclose, a.btnclose, #popup .close").each do |el|
        el.click if el.displayed?
      rescue Selenium::WebDriver::Error::WebDriverError
        next
      end
    rescue Selenium::WebDriver::Error::WebDriverError
      nil
    end

    def select_value(id, value)
      with_retry do
        select = Selenium::WebDriver::Support::Select.new(driver.find_element(id:))
        select.select_by(:value, value)
      end
    end

    def type_into(id, text)
      with_retry do
        field = driver.find_element(id:)
        field.clear
        field.send_keys(text)
      end
    end

    # Popups intercept normal clicks; dispatch the click via JS.
    def js_click(element)
      driver.execute_script("arguments[0].click();", element)
    end

    # ASP.NET AutoPostBack rebuilds the DOM, so element lookups go stale.
    def with_retry(tries: 4)
      attempt = 0
      begin
        yield
      rescue Selenium::WebDriver::Error::StaleElementReferenceError,
             Selenium::WebDriver::Error::NoSuchElementError
        attempt += 1
        if attempt < tries
          sleep 0.4
          retry
        end
        raise
      end
    end

    def wait(timeout: ELEMENT_TIMEOUT)
      Selenium::WebDriver::Wait.new(timeout:)
    end

    def wait_for_new_window(main, timeout: 10)
      wait(timeout:).until { (driver.window_handles - [main]).any? }
      (driver.window_handles - [main]).first
    rescue Selenium::WebDriver::Error::TimeoutError
      nil
    end

    def safe_switch(handle)
      driver.switch_to.window(handle)
    rescue Selenium::WebDriver::Error::WebDriverError
      nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

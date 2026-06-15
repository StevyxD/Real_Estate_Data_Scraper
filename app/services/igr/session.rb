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
    MAX_PAGES           = 200 # runaway guard for the results-grid page walk

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

      driver.switch_to.window(handle)
      html = driver.page_source
      driver.close
      driver.switch_to.window(main)
      dismiss_popup
      Igr::IndexIiParser.parse(html)
    rescue Selenium::WebDriver::Error::WebDriverError => e
      logger.warn("[igr] IndexII row #{row_index} failed: #{e.message}")
      safe_switch(main)
      nil
    end

    # Walk every page of the results grid for the current property, yielding the
    # parsed rows of each page (and its 1-based page number) with that page LIVE
    # in the DOM, so the caller can drive IndexII enrichment on it before we move
    # on. Page 1 is the rows solve_and_submit already found (passed in, so we do
    # NOT re-parse and race the async render); pages 2..N are reached by firing
    # the GridView's Page$N postback.
    #
    # We stop ONLY when the pager itself no longer lists a higher page number —
    # never because a page was slow to load. The slow portal is handled by
    # go_to_page, which re-fires and waits (up to 3 × PAGE_NAV_TIMEOUT) for the
    # next page to actually render. This is the fix for the old "stops at 10 docs"
    # bug, where a momentary empty/slow grid was misread as "no more pages".
    def each_result_page(first_rows = nil)
      rows = first_rows.presence || Igr::ResultParser.parse(driver.page_source)
      return if rows.blank?

      yield rows, 1
      target = pager_target
      logger.info("[igr] page 1: #{rows.size} rows, pager target=#{target.inspect}")
      return unless target # single page

      prev_first = rows.first.attrs[:doc_number]
      page = 1
      while page < MAX_PAGES
        # Deterministic end-of-pages: the pager only links to a number greater
        # than the current page while more pages remain. Don't infer the end from
        # a render timeout (a slow page would be mistaken for the last one).
        break unless Igr::ResultParser.pager_pages(driver.page_source).any? { |n| n > page }

        page += 1
        rows = go_to_page(target, page, prev_first)
        if rows.blank? || rows.first.attrs[:doc_number] == prev_first
          logger.warn("[igr] page #{page}: expected (pager lists it) but it did not load — stopping")
          break
        end

        logger.info("[igr] page #{page}: #{rows.size} rows (first=#{rows.first.attrs[:doc_number]})")
        prev_first = rows.first.attrs[:doc_number]
        yield rows, page
      end
    end

    private

    # The GridView's pager-postback target ('RegistrationGrid'), or nil for a
    # genuine single-page grid. Retries briefly: right after results land the DOM
    # can still be mid-render, and reading too early would mistake a paged grid
    # for a single page and skip pages 2..N.
    def pager_target(tries: 6)
      tries.times do
        target = Igr::ResultParser.pager_target(driver.page_source)
        return target if target

        sleep 0.3
      end
      nil
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

    def open_search
      driver.navigate.to(BASE_URL)
      dismiss_popup            # intro "Search Flow" popup overlays every load
      open_tab                 # subclass: JS-click the tab to reveal its form
      dismiss_popup
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

    def wait(timeout: 15)
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

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
    PAGE_TIMEOUT        = 45

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

    private

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

module Igr
  # The "Rest of Maharashtra / उर्वरित महाराष्ट्र" tab, which has a
  # District -> Tahsil -> Village cascade (each an AutoPostBack <select>).
  # Used for every non-Mumbai property (Property#mumbai? == false).
  #
  # The English -> site-value maps below currently cover only the villages we
  # have scraped; extend them for new talukas/villages. (Verified via the probe
  # scripts in script/.)
  class RestMaharashtraSession < Session
    TAB_BUTTON = "btnOtherdistrictSearch".freeze

    DISTRICT_VALUES = {
      "Raigad" => "7"
    }.freeze

    # NOTE the TRAILING SPACE in Panvel's value — it is part of the option value.
    TAHSIL_VALUES = {
      "Panvel" => "2 "
    }.freeze

    # Village option values are the Marathi label text.
    VILLAGE_VALUES = {
      "Kharghar" => "खारघर"
    }.freeze

    private

    def captcha_image_id = "imgCaptcha_new"
    def captcha_input_id = "txtImg1"
    def submit_button_id = "btnSearch_RestMaha"

    def open_tab
      js_click(wait.until { driver.find_element(id: TAB_BUTTON) })
    end

    def fill_form(property)
      select_value("ddlFromYear1", property.year.to_s)

      select_value("ddlDistrict1", lookup(DISTRICT_VALUES, property.district, "district"))
      wait_for_options("ddltahsil")

      select_value("ddltahsil", lookup(TAHSIL_VALUES, property.tahsil, "tahsil"))
      wait_for_options("ddlvillage")

      select_value("ddlvillage", lookup(VILLAGE_VALUES, property.village, "village"))

      # The village select fires an async postback that re-renders (and BLANKS)
      # the property-number field. Wait for it to settle, THEN set the number —
      # otherwise the late re-render wipes it and the search posts an empty
      # property number (silently returning zero rows).
      wait_idle
      sleep 0.5
      type_into("txtAttributeValue1", property.property_no.to_s)
    end

    # Before every attempt: re-assert the property number (a prior failed-search
    # postback re-renders and blanks it) and force a fresh captcha.
    def prepare_attempt
      wait_idle
      dismiss_popup # the intro popup re-overlays after every postback
      set_property_number(@property.property_no.to_s)
      refresh_captcha
    end

    # On a retry the field can be transiently non-interactable right after the
    # failed-search postback re-render; we've already wait_idle'd, so a JS value
    # set serializes correctly and is a safe fallback to native typing.
    def set_property_number(value)
      type_into("txtAttributeValue1", value)
    rescue Selenium::WebDriver::Error::InvalidElementStateError,
           Selenium::WebDriver::Error::ElementNotInteractableError
      driver.execute_script(
        "const e = document.getElementById('txtAttributeValue1'); if (e) e.value = arguments[0];",
        value
      )
    end

    # CRITICAL: the captcha image is static per page load, but the dropdown
    # cascade desyncs the server-side captcha value from it — so a correct read of
    # the stale image is REJECTED (the green "Entered Correct Captcha" label is a
    # red herring; it shows even for a wrong captcha). Force a fresh Handler.ashx
    # GET right before solving so the displayed image matches the server's value.
    def refresh_captcha
      driver.execute_script(<<~JS, captcha_image_id)
        const img = document.getElementById(arguments[0]);
        if (img) img.src = img.src.split('?')[0] + '?txt=' + Math.random().toString(36).slice(2);
      JS
      wait.until do
        driver.execute_script(
          "const i = document.getElementById(arguments[0]); return !!(i && i.complete && i.naturalWidth > 0);",
          captcha_image_id
        )
      end
      sleep 0.3
    end

    # Clicking the Search button (synthetic OR native) does NOT trigger the
    # ASP.NET AJAX postback here. Firing __doPostBack via a setTimeout'd STRING
    # (exactly as the site's own dropdown handlers do) runs in global non-strict
    # scope — avoiding the strict-mode "arguments" error — and performs the proper
    # async search postback.
    def submit_search(guess)
      dismiss_popup # re-overlays after each postback and intercepts the field
      begin
        field = driver.find_element(id: captcha_input_id)
        field.clear
        field.send_keys(guess)
      rescue Selenium::WebDriver::Error::InvalidElementStateError,
             Selenium::WebDriver::Error::ElementNotInteractableError
        driver.execute_script(
          "const e = document.getElementById(arguments[0]); if (e) { e.value = ''; e.value = arguments[1]; }",
          captcha_input_id, guess
        )
      end
      driver.execute_script("setTimeout(\"__doPostBack('#{submit_button_id}','')\", 0);")
    end

    def lookup(map, key, label)
      map.fetch(key) do
        raise ArgumentError, "Unknown Rest-Maharashtra #{label} #{key.inspect} " \
                             "(add it to RestMaharashtraSession)"
      end
    end

    def wait_for_options(id, timeout: 15)
      wait(timeout:).until do
        driver.find_elements(css: "##{id} option").size > 1
      end
    rescue Selenium::WebDriver::Error::TimeoutError
      nil
    end
  end
end

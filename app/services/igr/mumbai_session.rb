module Igr
  # The original "Mumbai" search tab. Districts are Mumbai City / Mumbai Suburban
  # (Marathi labels in the dropdown, so we select by VALUE). The village field
  # (txtAreaName) feeds a "Select Village" dropdown (ddlareaname) that only
  # populates AFTER the field BLURS, so we tab out and wait before selecting.
  class MumbaiSession < Session
    TAB_BUTTON = "btnMumbaisearch".freeze

    # English district -> dropdown value. "30" = Mumbai City (where Parel is),
    # "31" = Mumbai Suburban.
    DISTRICT_VALUES = {
      "Mumbai City"     => "30",
      "Mumbai Suburban" => "31"
    }.freeze

    private

    def captcha_image_id = "imgCaptcha"
    def captcha_input_id = "txtImg"
    def submit_button_id = "btnSearch"

    # The intro popup intercepts a normal click on the tab, so JS-click it.
    def open_tab
      js_click(wait.until { driver.find_element(id: TAB_BUTTON) })
    end

    def fill_form(property)
      select_value("ddlFromYear", property.year.to_s)
      select_value("ddlDistrict", district_value(property))
      sleep 2 # ddlDistrict fires an AutoPostBack (__doPostBack) — let it settle
      dismiss_popup

      # Type the village, blur so ddlareaname autopopulates, then pick + verify.
      type_into("txtAreaName", property.village)
      blur("txtAreaName")
      select_village(property.village)

      type_into("txtAttributeValue", property.property_no.to_s)
    end

    def district_value(property)
      DISTRICT_VALUES.fetch(property.district) do
        raise ArgumentError, "Unknown Mumbai district #{property.district.inspect} " \
                             "(add it to MumbaiSession::DISTRICT_VALUES)"
      end
    end

    # Pick the village in ddlareaname and VERIFY the selection stuck. The dropdown
    # is filled by an async autocomplete after txtAreaName blurs, so the option
    # can appear late and a first click can race with a repopulation — hence the
    # poll + verify + retry. If the value never leaves the "-----Select Area----"
    # placeholder, btnSearch's required-field validator fails (Page_IsValid=false)
    # and the search is silently aborted (no postback, empty grid).
    def select_village(village)
      wanted = village.to_s.strip
      deadline = monotonic + 20

      loop do
        value = try_select_village(wanted)
        return value if value

        break if monotonic > deadline

        sleep 0.5
      end

      raise Selenium::WebDriver::Error::NoSuchElementError,
            "could not select village #{wanted.inspect} in ddlareaname (got #{areaname_value.inspect})"
    end

    # One attempt: select the matching option via Select#select_by (clicking the
    # <option> directly is unreliable in headless Chrome), then read back the
    # select's value. Returns the value if it stuck (not the placeholder), else nil.
    def try_select_village(wanted)
      with_retry do
        select = Selenium::WebDriver::Support::Select.new(driver.find_element(id: "ddlareaname"))
        option = select.options.find { |o| o.text.to_s.strip.casecmp?(wanted) } ||
                 select.options.find { |o| real_option?(o) }
        return nil unless option

        select.select_by(:text, option.text)
      end
      sleep 0.2
      value = areaname_value
      real_value?(value) ? value : nil
    rescue Selenium::WebDriver::Error::WebDriverError
      nil
    end

    def areaname_value
      driver.find_element(id: "ddlareaname").attribute("value").to_s.strip
    rescue Selenium::WebDriver::Error::WebDriverError
      ""
    end

    def real_value?(value)
      !value.to_s.strip.empty? && !/select area/i.match?(value.to_s)
    end

    def real_option?(option)
      option.attribute("value").to_s.strip != "" && !/select area/i.match?(option.text.to_s)
    end

    def blur(id)
      driver.execute_script("document.getElementById(arguments[0]).blur();", id)
    end
  end
end

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

      # Type the village, then blur so ddlareaname autopopulates.
      type_into("txtAreaName", property.village)
      blur("txtAreaName")
      wait_for_options("ddlareaname")
      select_village(property.village)

      type_into("txtAttributeValue", property.property_no.to_s)
    end

    def district_value(property)
      DISTRICT_VALUES.fetch(property.district) do
        raise ArgumentError, "Unknown Mumbai district #{property.district.inspect} " \
                             "(add it to MumbaiSession::DISTRICT_VALUES)"
      end
    end

    # Pick the village option whose text matches; fall back to the first real one.
    def select_village(village)
      with_retry do
        select = Selenium::WebDriver::Support::Select.new(driver.find_element(id: "ddlareaname"))
        match = select.options.find { |o| o.text.to_s.strip.casecmp?(village.to_s.strip) }
        (match || select.options.find { |o| o.attribute("value").to_s != "" }).click
      end
    end

    def blur(id)
      driver.execute_script("document.getElementById(arguments[0]).blur();", id)
    end

    # ddlareaname is empty until the AutoPostBack fills it.
    def wait_for_options(id, timeout: 15)
      wait(timeout:).until do
        driver.find_elements(css: "##{id} option").size > 1
      end
    rescue Selenium::WebDriver::Error::TimeoutError
      nil
    end
  end
end

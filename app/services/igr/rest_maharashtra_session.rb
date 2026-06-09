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

      type_into("txtAttributeValue1", property.property_no.to_s)
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

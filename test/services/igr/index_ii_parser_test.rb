require "test_helper"

class Igr::IndexIiParserTest < ActiveSupport::TestCase
  SECTIONS = {
    "1"  => "करारनामा",
    "2"  => "16147750",
    "3"  => "14714836.5",
    "4"  => "इतर माहिती: सदनिका नं. 1101,अकरावा मजला,क्रिस्टल कॉर्नर,प्लॉट नं. 110,सेक्टर - 11,खारघर,चटई क्षेत्र 91.15 चौ.मी.",
    "5"  => "91.15 चौ.मीटर",
    "7"  => "1):  नाव:-मे. बिल्डर्स   पिन कोड:-410210 पॅन नं:-AAHFF7861P",
    "8"  => "1):  नाव:-हर्षद कुंभार   पॅन नं:-AQYPK3497R",
    "9"  => "02/06/2026",
    "10" => "03/06/2026",
    "12" => "1130400",
    "13" => "30000"
  }.freeze

  setup { @attrs = Igr::IndexIiParser.from_sections(SECTIONS).attrs }

  test "parses amounts only from numeric sections" do
    assert_equal "16147750".to_d, @attrs[:consideration_amount]
    assert_equal "14714836.5".to_d, @attrs[:market_value]
    assert_equal "1130400".to_d, @attrs[:stamp_duty]
    assert_equal "30000".to_d, @attrs[:registration_fee]
  end

  test "parses dd/mm/yyyy dates" do
    assert_equal Date.new(2026, 6, 3), @attrs[:registration_date]
    assert_equal Date.new(2026, 6, 2), @attrs[:execution_date]
  end

  test "splits area into number and unit" do
    assert_equal "91.15".to_d, @attrs[:area_sqft]
    assert_equal "चौ.मीटर", @attrs[:area_unit]
  end

  test "pulls PAN from the party blocks" do
    assert_equal "AAHFF7861P", @attrs[:seller_pan]
    assert_equal "AQYPK3497R", @attrs[:purchaser_pan]
  end

  test "extracts the building name" do
    assert_equal "क्रिस्टल कॉर्नर", @attrs[:building_name]
  end

  test "to_amount rejects lease-rent free text (no false-positive value)" do
    attrs = Igr::IndexIiParser.from_sections("3" => "a) Rs. 20000/- per month for the first 12 months").attrs
    assert_nil attrs[:market_value]
  end
end

require "test_helper"

class Igr::BuildingNameTest < ActiveSupport::TestCase
  def call(description) = Igr::BuildingName.call(description)

  test "comma-separated: name sits between floor and plot" do
    desc = "इतर माहिती: सदनिका नं. 1101,अकरावा मजला,क्रिस्टल कॉर्नर,प्लॉट नं. 110,सेक्टर - 11,खारघर"
    assert_equal "क्रिस्टल कॉर्नर", call(desc)
  end

  test "free space-separated description" do
    desc = "इतर माहिती: सदनिका क 1703 17 वा मजला किस्टोन एलिटा सी एच एस लि प्लॉट नं 49 सेक्टर 15 खारघर"
    assert_equal "किस्टोन एलिटा सी एच एस लि", call(desc)
  end

  test "drops a leading wing token" do
    desc = "सदनिका नं 502,पाचवा मजला,बी विंग सत्यम सूर्या मॅनहॅटन,प्लॉट नं 5,सेक्टर 20"
    assert_equal "सत्यम सूर्या मॅनहॅटन", call(desc)
  end

  test "nil for a plot-only sale (no unit or floor)" do
    assert_nil call("प्लॉट नं 49,सेक्टर 15,खारघर,नवी मुंबई")
  end

  test "nil for blank input" do
    assert_nil call("")
    assert_nil call(nil)
  end
end

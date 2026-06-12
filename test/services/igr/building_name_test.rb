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

  test "labelled name stops at a trailing Marathi विंग token" do
    desc = "इमारतीचे नाव: रागुवंशी मिल कंपाऊंड,विंग बी,प्रथमेश बिल्डिंग, ब्लॉक नं: लोवर परेल,मुंबई 400013"
    assert_equal "रागुवंशी मिल कंपाऊंड", call(desc)
  end

  test "labelled name keeps a hyphen-attached wing but stops at ब्लॉक" do
    desc = "इमारतीचे नाव: अशोक टॉवर्स बी-विंग, ब्लॉक नं: परेल,मुम्बई 400012"
    assert_equal "अशोक टॉवर्स बी-विंग", call(desc)
  end

  test "labelled name keeps विंग्स as part of the society name" do
    desc = "इमारतीचे नाव: सोयूझ कॉम्प्लेक्स ए.बी.सी. अँड डी. विंग्स सी.एच.एस, ब्लॉक नं: चेंबूर"
    assert_equal "सोयूझ कॉम्प्लेक्स ए.बी.सी. अँड डी. विंग्स सी.एच.एस", call(desc)
  end

  test "nil for a plot-only sale (no unit or floor)" do
    assert_nil call("प्लॉट नं 49,सेक्टर 15,खारघर,नवी मुंबई")
  end

  test "nil for blank input" do
    assert_nil call("")
    assert_nil call(nil)
  end
end

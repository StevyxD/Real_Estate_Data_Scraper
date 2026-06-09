require "test_helper"

class DocumentTest < ActiveSupport::TestCase
  def doc(attrs = {})
    Document.new({ doc_type: "सेल डीड" }.merge(attrs))
  end

  test "sale_category classifies the Marathi doc type" do
    assert_equal :sale,     doc(doc_type: "सेल डीड").sale_category
    assert_equal :sale,     doc(doc_type: "करारनामा").sale_category
    assert_equal :lease,    doc(doc_type: "36-अ-लिव्ह अॅड लायसन्सेस").sale_category
    assert_equal :gift,     doc(doc_type: "बक्षीसपत्र").sale_category
    assert_equal :mortgage, doc(doc_type: "गहाणखत").sale_category
    assert_equal :other,    doc(doc_type: "काहीतरी").sale_category
  end

  test "parses parties from the postgres-array literal" do
    assert_equal ["नाव अ", "नाव ब"], doc(seller_names: %q({"नाव अ","नाव ब"})).sellers
    assert_equal [], doc(seller_names: nil).sellers
  end

  test "carpet_sqft converts square metres but leaves square feet" do
    assert_in_delta 1000 * Document::SQM_TO_SQFT, doc(area_sqft: 1000, area_unit: "चौ.मीटर").carpet_sqft, 0.01
    assert_equal 1267, doc(area_sqft: 1267, area_unit: "चौ.फूट").carpet_sqft
  end

  test "rate_per_sqft is nil without consideration or area" do
    assert_nil doc(consideration_amount: 0, area_sqft: 100).rate_per_sqft
    assert_nil doc(consideration_amount: 1_000_000, area_sqft: nil).rate_per_sqft
  end

  test "infers pincode from village on save; a literal pincode wins" do
    property = Property.create!(year: 2026, district: "Raigad", tahsil: "Panvel",
                                village: "Kharghar", property_no: 99_999)
    inferred = property.documents.create!(doc_number: "TEST-1")
    literal  = property.documents.create!(doc_number: "TEST-2", pincode: "400001")

    assert_equal "410210", inferred.pincode
    assert_equal "400001", literal.pincode
  end
end

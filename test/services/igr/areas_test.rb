require "test_helper"

class Igr::AreasTest < ActiveSupport::TestCase
  test "districts come from the mapping" do
    assert_equal ["Mumbai City", "Mumbai Suburban"], Igr::Areas.districts
  end

  test "areas are grouped under the right district" do
    assert_includes Igr::Areas.areas_for("Mumbai City"), "Parel"
    assert_includes Igr::Areas.areas_for("Mumbai Suburban"), "Bandra"
    assert_not_includes Igr::Areas.areas_for("Mumbai City"), "Bandra"
  end

  test "valid? checks district/area membership" do
    assert Igr::Areas.valid?("Mumbai City", "Parel")
    assert_not Igr::Areas.valid?("Mumbai City", "Bandra")
    assert_not Igr::Areas.valid?("Nowhere", "Parel")
  end
end

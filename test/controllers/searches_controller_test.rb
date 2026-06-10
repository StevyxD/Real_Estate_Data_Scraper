require "test_helper"

class SearchesControllerTest < ActionDispatch::IntegrationTest
  test "new renders the form (district select + village text field)" do
    get search_path
    assert_response :success
    assert_select "select#search_district"
    assert_select "input#search_village"
  end

  test "create queues a scrape for a valid Mumbai selection" do
    assert_difference -> { Property.count }, 1 do
      assert_enqueued_with(job: ScrapePropertyJob) do
        post search_path, params: { search: { year: 2026, district: "Mumbai City", village: "Parel", property_no: 4242 } }
      end
    end

    property = Property.find_by!(village: "Parel", property_no: 4242)
    assert property.pending?
    assert_equal "", property.tahsil
    assert_redirected_to dashboard_path
  end

  test "create rejects a blank village or an unknown district" do
    assert_no_difference -> { Property.count } do
      post search_path, params: { search: { year: 2026, district: "Mumbai City", village: "", property_no: 1 } }
      assert_response :unprocessable_entity
      post search_path, params: { search: { year: 2026, district: "Nowhere", village: "Parel", property_no: 1 } }
      assert_response :unprocessable_entity
    end
  end
end

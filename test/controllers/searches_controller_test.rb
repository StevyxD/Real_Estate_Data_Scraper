require "test_helper"

class SearchesControllerTest < ActionDispatch::IntegrationTest
  test "new renders the form (district select + village text field)" do
    get search_path
    assert_response :success
    assert_select "select#search_district"
    assert_select "input#search_village"
  end

  # Enqueuing is owned by ScrapeDispatcherJob (recurring); the controller just
  # makes the target due.
  test "create makes a valid Mumbai selection due for scraping" do
    assert_difference -> { Property.count }, 1 do
      post search_path, params: { search: { year: 2026, district: "Mumbai City", village: "Parel", property_no: 4242 } }
    end

    property = Property.find_by!(village: "Parel", property_no: 4242)
    assert property.pending?
    assert_nil property.next_retry_at
    assert Property.due.exists?(property.id)
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

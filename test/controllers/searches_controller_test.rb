require "test_helper"

class SearchesControllerTest < ActionDispatch::IntegrationTest
  test "new renders the form with the dependent selects" do
    get search_path
    assert_response :success
    assert_select "select#search_district"
    assert_select "select#search_village"
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
    assert_redirected_to documents_path
  end

  test "create rejects an area that does not belong to the district" do
    assert_no_difference -> { Property.count } do
      post search_path, params: { search: { year: 2026, district: "Mumbai City", village: "Bandra", property_no: 1 } }
    end
    assert_response :unprocessable_entity
  end
end

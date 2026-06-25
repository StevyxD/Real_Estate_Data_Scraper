require "test_helper"

class KhargharScrapesControllerTest < ActionDispatch::IntegrationTest
  test "new renders the form (year select + from/to number fields)" do
    get kharghar_scrape_path
    assert_response :success
    assert_select "select#kharghar_year"
    assert_select "input#kharghar_from_no"
    assert_select "input#kharghar_to_no"
  end

  # Enqueuing is now owned by ScrapeDispatcherJob (recurring); the controller
  # just makes the targets due (pending + cleared retry state).
  test "create makes every property no. in the range due, fixed to Kharghar" do
    assert_difference -> { Property.count }, 3 do
      post kharghar_scrape_path, params: { kharghar: { year: 2026, from_no: 10, to_no: 12 } }
    end

    props = Property.where(village: "Kharghar", year: 2026, property_no: 10..12).order(:property_no)
    assert_equal [10, 11, 12], props.map(&:property_no)
    props.each do |p|
      assert p.pending?
      assert_nil p.next_retry_at, "should be due immediately"
      assert_equal "Raigad", p.district
      assert_equal "Panvel", p.tahsil
      assert Property.due.exists?(p.id)
    end
    assert_redirected_to dashboard_path
  end

  test "create with a blank To makes just the single From property due" do
    assert_difference -> { Property.count }, 1 do
      post kharghar_scrape_path, params: { kharghar: { year: 2026, from_no: 5, to_no: "" } }
    end

    prop = Property.find_by!(village: "Kharghar", year: 2026, property_no: 5)
    assert prop.pending?
    assert_equal "Panvel", prop.tahsil
    assert Property.due.exists?(prop.id)
    assert_redirected_to dashboard_path
  end

  test "create re-queues an already-found property so it gets re-scraped in full" do
    existing = Property.create!(year: 2026, district: "Raigad", tahsil: "Panvel",
                                village: "Kharghar", property_no: 50, search_status: "found")

    assert_no_difference -> { Property.count } do
      post kharghar_scrape_path, params: { kharghar: { year: 2026, from_no: 50, to_no: 50 } }
    end
    assert existing.reload.pending?
    assert Property.due.exists?(existing.id)
  end

  test "create rejects from > to, non-positive, and oversized ranges" do
    assert_no_difference -> { Property.count } do
      post kharghar_scrape_path, params: { kharghar: { year: 2026, from_no: 20, to_no: 10 } }
      assert_response :unprocessable_entity

      post kharghar_scrape_path, params: { kharghar: { year: 2026, from_no: 0, to_no: 5 } }
      assert_response :unprocessable_entity

      over = KhargharScrapesController::MAX_RANGE + 1
      post kharghar_scrape_path, params: { kharghar: { year: 2026, from_no: 1, to_no: over } }
      assert_response :unprocessable_entity
    end
  end
end

require "test_helper"

class KhargharScrapesControllerTest < ActionDispatch::IntegrationTest
  test "new renders the form (year select + from/to number fields)" do
    get kharghar_scrape_path
    assert_response :success
    assert_select "select#kharghar_year"
    assert_select "input#kharghar_from_no"
    assert_select "input#kharghar_to_no"
  end

  test "create queues a scrape for every property no. in the range, fixed to Kharghar" do
    assert_difference -> { Property.count }, 3 do
      assert_enqueued_jobs 3, only: ScrapePropertyJob do
        post kharghar_scrape_path, params: { kharghar: { year: 2026, from_no: 10, to_no: 12 } }
      end
    end

    props = Property.where(village: "Kharghar", year: 2026, property_no: 10..12).order(:property_no)
    assert_equal [10, 11, 12], props.map(&:property_no)
    props.each do |p|
      assert p.pending?
      assert_equal "Raigad", p.district
      assert_equal "Panvel", p.tahsil
    end
    assert_redirected_to dashboard_path
  end

  test "create with a blank To queues just the single From property" do
    assert_difference -> { Property.count }, 1 do
      assert_enqueued_jobs 1, only: ScrapePropertyJob do
        post kharghar_scrape_path, params: { kharghar: { year: 2026, from_no: 5, to_no: "" } }
      end
    end

    prop = Property.find_by!(village: "Kharghar", year: 2026, property_no: 5)
    assert prop.pending?
    assert_equal "Panvel", prop.tahsil
    assert_redirected_to dashboard_path
  end

  test "create re-queues an already-found property so it gets re-scraped in full" do
    existing = Property.create!(year: 2026, district: "Raigad", tahsil: "Panvel",
                                village: "Kharghar", property_no: 50, search_status: "found")

    assert_no_difference -> { Property.count } do
      assert_enqueued_with(job: ScrapePropertyJob) do
        post kharghar_scrape_path, params: { kharghar: { year: 2026, from_no: 50, to_no: 50 } }
      end
    end
    assert existing.reload.pending?
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

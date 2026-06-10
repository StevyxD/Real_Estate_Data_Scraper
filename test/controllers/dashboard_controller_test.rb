require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  test "renders the dashboard with status sections" do
    property = Property.create!(year: 2026, district: "Mumbai City", tahsil: "",
                                village: "Parel", property_no: 7777, search_status: "scraping")
    property.documents.create!(doc_number: "D1", consideration_amount: 5_000_000)

    get dashboard_path
    assert_response :success
    assert_select "h1", text: "Dashboard"
    assert_match "Scrape activity", response.body
    assert_match "Recently scraped documents", response.body
  end
end

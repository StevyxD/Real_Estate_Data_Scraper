require "test_helper"

class ScrapeControlsControllerTest < ActionDispatch::IntegrationTest
  teardown { Igr::ScrapeControl.resume! } # never leave the test queue paused

  test "pause pauses the scraping queue and redirects to the dashboard" do
    Igr::ScrapeControl.resume!
    post scraper_pause_path
    assert Igr::ScrapeControl.paused?
    assert_redirected_to dashboard_path
  end

  test "resume unpauses the scraping queue" do
    Igr::ScrapeControl.pause!
    post scraper_resume_path
    refute Igr::ScrapeControl.paused?
    assert_redirected_to dashboard_path
  end

  test "dispatcher enqueues nothing while paused" do
    Property.create!(year: 2026, district: "Raigad", tahsil: "Panvel",
                     village: "Kharghar", property_no: 90_001, search_status: "pending")
    Igr::ScrapeControl.pause!

    assert_no_enqueued_jobs only: ScrapePropertyJob do
      ScrapeDispatcherJob.perform_now
    end
  end
end

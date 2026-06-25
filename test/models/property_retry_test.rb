require "test_helper"

# The unattended-retry behavior: "property #1 failed — when do we come back?"
class PropertyRetryTest < ActiveSupport::TestCase
  def build(attrs = {})
    Property.create!({ year: 2026, district: "Raigad", tahsil: "Panvel",
                       village: "Kharghar", property_no: rand(1..1_000_000) }.merge(attrs))
  end

  test "a fresh pending property is due immediately" do
    p = build(search_status: "pending")
    assert Property.due.exists?(p.id)
  end

  test "an outage failure parks the property briefly without burning an attempt" do
    p = build(search_status: "error")
    p.schedule_retry!(kind: :outage, error: "timed out")

    assert_equal 0, p.attempts, "outages must not count toward giving up"
    assert_equal "outage", p.last_error_kind
    assert p.next_retry_at > Time.current
    assert p.next_retry_at <= Time.current + Property::RETRY_CAP + 1.minute
    refute Property.due.exists?(p.id), "not due until its backoff elapses"
  end

  test "an app failure burns an attempt and backs off exponentially" do
    p = build(search_status: "error")
    p.schedule_retry!(kind: :app, error: "boom")
    first = p.next_retry_at - Time.current

    p.schedule_retry!(kind: :app, error: "boom")
    second = p.next_retry_at - Time.current

    assert_equal 2, p.attempts
    assert second > first, "backoff window should grow with attempts"
  end

  test "after MAX_ATTEMPTS app failures the property is given up on (dead, not due)" do
    p = build(search_status: "error")
    Property::MAX_ATTEMPTS.times { p.schedule_retry!(kind: :app, error: "boom") }

    assert_equal Property::MAX_ATTEMPTS, p.attempts
    assert_nil p.next_retry_at
    assert p.error?
    refute Property.due.exists?(p.id)
    assert Property.dead.exists?(p.id)
  end

  test "a property whose backoff has elapsed becomes due again" do
    p = build(search_status: "error", attempts: 1, next_retry_at: 1.minute.ago)
    assert Property.due.exists?(p.id)
  end

  test "a property actively being scraped is never due" do
    p = build(search_status: "scraping", next_retry_at: nil)
    refute Property.due.exists?(p.id)
  end

  test "lease pushes next_retry_at out so the dispatcher won't double-hand-out" do
    p = build(search_status: "pending")
    p.lease!
    assert p.next_retry_at > Time.current + (Property::ENQUEUE_LEASE - 1.minute)
    refute Property.due.exists?(p.id)
  end

  test "found-but-incomplete is due (resume), found-and-complete is not" do
    incomplete = build(search_status: "found", fully_scraped: false, next_retry_at: nil)
    complete   = build(search_status: "found", fully_scraped: true,  next_retry_at: nil)
    assert Property.due.exists?(incomplete.id)
    refute Property.due.exists?(complete.id)
  end
end

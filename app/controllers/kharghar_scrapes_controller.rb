# Bulk scrape form dedicated to Kharghar (Raigad / Panvel). The user enters only
# year + a property-number range; the district/tahsil/village are fixed here, so
# every number in [from..to] is find-or-created and queued on the :scraping queue
# (run `bin/jobs` to process). Re-queuing an already-scraped property re-scrapes
# it from scratch, so it picks up ALL document pages.
class KhargharScrapesController < ApplicationController
  YEARS = (2010..Date.current.year).to_a.reverse

  DISTRICT = "Raigad".freeze
  TAHSIL   = "Panvel".freeze
  VILLAGE  = "Kharghar".freeze

  # Cap per submit so one request doesn't enqueue an unbounded number of jobs
  # (and time out). Larger backfills are done as several submits.
  MAX_RANGE = 2000

  def new
    @years = YEARS
    @form  = { year: Date.current.year.to_s, from_no: "", to_no: "" }
  end

  def create
    @form = form_params.to_h.symbolize_keys
    year  = @form[:year].to_i
    from  = @form[:from_no].to_i
    # "To" is optional — blank means a single property (just "From").
    to    = @form[:to_no].present? ? @form[:to_no].to_i : from

    if (message = validate(year, from, to))
      return render_invalid(message)
    end

    queued = enqueue_range(year, from..to)
    # Seeding intent = run it: lift any earlier "Stop & clear" pause (no-op if not
    # paused). enqueue_range already (re)sets each row to pending, reviving parked.
    Igr::ScrapeControl.resume! if queued.positive?
    redirect_to dashboard_path,
                notice: "Queued #{queued} Kharghar #{'property'.pluralize(queued)} " \
                        "(##{from}–#{to}, #{year}) for scraping. Run `bin/jobs` to start " \
                        "the worker — watch progress below."
  end

  private

  def validate(year, from, to)
    return "Pick a valid year." unless YEARS.include?(year)
    return "Enter a From property number (1 or greater)." unless from.positive?
    return "To property no. can't be less than From." if to < from
    if (to - from + 1) > MAX_RANGE
      return "That's #{to - from + 1} properties — max #{MAX_RANGE} per submit. Split it into smaller ranges."
    end

    nil
  end

  # find-or-create each property in the range, (re)set it to pending, and enqueue
  # a scrape. Returns how many were queued.
  def enqueue_range(year, range)
    range.sum do |number|
      property = Property.find_or_initialize_by(
        year:, district: DISTRICT, tahsil: TAHSIL, village: VILLAGE, property_no: number
      )
      property.assign_attributes(search_status: "pending", attempts: 0, next_retry_at: nil,
                                 error_message: nil)
      next 0 unless property.save

      1 # ScrapeDispatcherJob will pick it up and retry on failure
    end
  end

  def form_params
    params.require(:kharghar).permit(:year, :from_no, :to_no)
  end

  def render_invalid(message)
    @years = YEARS
    flash.now[:alert] = message
    render :new, status: :unprocessable_entity
  end
end

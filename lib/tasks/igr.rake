# IGR scraping tasks. Seeding find-or-creates Property rows and makes them due;
# the recurring ScrapeDispatcherJob (started by `bin/jobs`) scrapes them and
# retries failures with backoff — unattended.
#
#   rake igr:scrape_parel               # seed Parel #1..10 / 2026
#   IGR_FROM=11 IGR_TO=50 rake igr:scrape_parel
#   rake igr:scrape_kharghar            # seed Kharghar (Raigad/Panvel) #1..10 / 2026
#   rake igr:scrape_pending             # make every pending/error/incomplete property due now
#   rake igr:status                     # progress dashboard + portal health
#   rake igr:retry_dead                 # revive properties given up on after MAX_ATTEMPTS
#   IGR_PROPERTY_ID=123 rake igr:scrape_one   # run one synchronously (debug)
module IgrRake
  module_function

  # Seed Property rows and make them due. We no longer enqueue jobs directly:
  # ScrapeDispatcherJob (recurring, every minute) claims due rows, retries
  # failures with backoff, and gates on the portal's health. Just leave
  # `bin/jobs` running and the targets get scraped — and re-scraped on failure —
  # unattended.
  def enqueue_range(district:, village:, year:, range:, tahsil: "")
    seeded = 0
    range.each do |number|
      property = Property.find_or_create_by!(
        year:, district:, tahsil:, village:, property_no: number
      )
      next unless property.pending? || property.error?

      property.update!(search_status: "pending", attempts: 0,
                       next_retry_at: nil, error_message: nil)
      seeded += 1
    end
    puts "Seeded #{seeded} of #{range.size} properties for #{[village, tahsil, district].reject(&:blank?).join(' / ')} #{year}."
    puts "Run `bin/jobs` — the dispatcher will scrape (and retry) them automatically."
  end

  def int_env(key, default)
    (ENV[key] || default).to_i
  end
end

namespace :igr do
  desc "Seed + enqueue Parel (Mumbai City) #IGR_FROM..IGR_TO (default 1..10), year IGR_YEAR (2026)"
  task scrape_parel: :environment do
    IgrRake.enqueue_range(
      district: "Mumbai City", village: "Parel",
      year:  IgrRake.int_env("IGR_YEAR", 2026),
      range: IgrRake.int_env("IGR_FROM", 1)..IgrRake.int_env("IGR_TO", 10)
    )
  end

  desc "Seed + enqueue Kharghar (Raigad / Panvel) #IGR_FROM..IGR_TO (default 1..10), year IGR_YEAR (2026)"
  task scrape_kharghar: :environment do
    IgrRake.enqueue_range(
      district: "Raigad", tahsil: "Panvel", village: "Kharghar",
      year:  IgrRake.int_env("IGR_YEAR", 2026),
      range: IgrRake.int_env("IGR_FROM", 1)..IgrRake.int_env("IGR_TO", 10)
    )
  end

  desc "Make every pending/error/incomplete property due now (dispatcher scrapes them)"
  task scrape_pending: :environment do
    count = Property.scrapable.update_all(next_retry_at: nil)
    puts "#{count} pending/error/incomplete properties are now due."
    puts "Run `bin/jobs` — the dispatcher picks them up within a minute."
  end

  desc "Revive properties given up on after MAX_ATTEMPTS (resets attempts so they retry)"
  task retry_dead: :environment do
    count = Property.dead.update_all(attempts: 0, next_retry_at: nil, search_status: "error")
    puts "Reset #{count} dead propert#{count == 1 ? 'y' : 'ies'} — they will be retried."
  end

  desc "Show scraper progress: status counts, how many are due / backing off / dead, site health"
  task status: :environment do
    counts = Property.group(:search_status).count
    total  = counts.values.sum
    puts "Properties (#{total} total):"
    %w[found empty pending scraping error].each do |s|
      puts format("  %-9s %d", s, counts[s].to_i)
    end
    puts format("  %-9s %d", "incomplete", Property.incomplete.where(search_status: "found").count)
    puts
    puts "Retry queue:"
    puts "  due now        #{Property.due.count}"
    puts "  backing off    #{Property.scrapable.where.not(search_status: 'scraping').where('next_retry_at > ?', Time.current).count}"
    puts "  dead (give up) #{Property.dead.count}"
    puts
    inflight = defined?(SolidQueue::Job) ? SolidQueue::Job.where(queue_name: "scraping", finished_at: nil).count : "n/a"
    puts "Jobs in flight (:scraping): #{inflight}"
    puts "Outage suspected (DB):      #{ScrapeDispatcherJob.site_down?}"
    print "Portal reachable now:       "
    puts Igr::SiteHealth.up? ? "yes" : "NO"
    docs = Document.count
    puts "Documents scraped:          #{docs}"
  end

  desc "Re-scrape a village's properties with full pagination; stop after " \
       "IGR_MAX_FAILS (default 5) consecutive empty/error properties " \
       "(IGR_VILLAGE=Kharghar, IGR_LIMIT=N to cap count, IGR_HEADED=1 to watch Chrome)"
  task rescrape: :environment do
    village  = ENV.fetch("IGR_VILLAGE", "Kharghar")
    max_fail = IgrRake.int_env("IGR_MAX_FAILS", 5)
    scope    = Property.where(village:).order(:property_no) # every status
    scope    = scope.limit(IgrRake.int_env("IGR_LIMIT", 0)) if ENV["IGR_LIMIT"].present?

    puts "Re-scraping #{scope.count} #{village} properties (stop after #{max_fail} consecutive empty/error)."
    consecutive = 0

    # .each (not find_each): the scope is small (≤ a few hundred) and find_each
    # would ignore our property_no ordering and the IGR_LIMIT cap.
    scope.each do |property|
      before = property.documents.count
      begin
        result = Igr::PropertyScraper.call(property, headless: ENV["IGR_HEADED"] != "1")
        after  = property.documents.count

        if result.status == :found
          consecutive = 0
          puts "##{property.property_no}: #{before} -> #{after} docs (#{result.attempts} attempts)"
        else
          consecutive += 1
          puts "##{property.property_no}: #{result.status} [consecutive fails: #{consecutive}/#{max_fail}]"
        end
      rescue StandardError => e
        consecutive += 1
        puts "##{property.property_no}: ERROR #{e.class}: #{e.message} [consecutive: #{consecutive}/#{max_fail}]"
      end

      if consecutive >= max_fail
        puts "STOP: #{max_fail} consecutive empty/error properties — the site is likely blocking us."
        break
      end
    end
  end

  desc "Re-scrape ALL Kharghar properties with full pagination (stop after 5 consecutive empty/error)"
  task rescrape_kharghar: :environment do
    ENV["IGR_VILLAGE"] = "Kharghar"
    Rake::Task["igr:rescrape"].invoke
  end

  desc "Scrape one property synchronously for debugging (IGR_PROPERTY_ID=123, IGR_HEADED=1 to show Chrome)"
  task scrape_one: :environment do
    property = Property.find(ENV.fetch("IGR_PROPERTY_ID"))
    result = Igr::PropertyScraper.call(property, headless: ENV["IGR_HEADED"] != "1")
    puts "#{property.label} -> #{result.status} " \
         "(#{result.attempts} captcha attempts, #{property.documents.count} documents)"
  end
end

# IGR scraping tasks. Seeding find-or-creates Property rows and enqueues them on
# the :scraping queue; run `bin/jobs` (single worker) to process them.
#
#   rake igr:scrape_parel               # Parel #1..10 / 2026
#   IGR_FROM=11 IGR_TO=50 rake igr:scrape_parel
#   rake igr:scrape_kharghar            # Kharghar (Raigad/Panvel) #1..10 / 2026
#   rake igr:scrape_pending             # (re)enqueue every pending/error property
#   IGR_PROPERTY_ID=123 rake igr:scrape_one   # run one synchronously (debug)
module IgrRake
  module_function

  def enqueue_range(district:, village:, year:, range:, tahsil: "")
    enqueued = 0
    range.each do |number|
      property = Property.find_or_create_by!(
        year:, district:, tahsil:, village:, property_no: number
      )
      next unless property.pending? || property.error?

      property.update!(enqueued_at: Time.current)
      ScrapePropertyJob.perform_later(property.id)
      enqueued += 1
    end
    puts "Enqueued #{enqueued} of #{range.size} properties for #{[village, tahsil, district].reject(&:blank?).join(' / ')} #{year}."
    puts "Run `bin/jobs` to process the :scraping queue."
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

  desc "(Re)enqueue every pending/error property on the :scraping queue"
  task scrape_pending: :environment do
    count = 0
    Property.scrapable.find_each do |property|
      property.update!(enqueued_at: Time.current)
      ScrapePropertyJob.perform_later(property.id)
      count += 1
    end
    puts "Enqueued #{count} pending/error properties. Run `bin/jobs`."
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

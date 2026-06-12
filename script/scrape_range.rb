# Synchronously scrape a contiguous property-no range for one area, in order,
# with a consecutive-error circuit breaker. Runs a single headless Chrome
# (NO bin/jobs / no second browser).
#
#   IGR_FROM=51 IGR_TO=100 bin/rails runner script/scrape_range.rb
#
# Stops early after MAX_CONSECUTIVE_ERRORS (default 5) scrapes raise in a row.
# :found and :empty both reset the streak; only :error (an exception) counts.

district = ENV.fetch("IGR_DISTRICT", "Raigad")
tahsil   = ENV.fetch("IGR_TAHSIL",   "Panvel")
village  = ENV.fetch("IGR_VILLAGE",  "Kharghar")
year     = (ENV["IGR_YEAR"] || 2026).to_i
from     = (ENV["IGR_FROM"] || 1).to_i
to       = (ENV["IGR_TO"]   || 10).to_i
max_consecutive_errors = (ENV["IGR_MAX_ERRORS"] || 5).to_i

puts "Scraping #{village} / #{tahsil} / #{district} #{year}, property_no #{from}..#{to}"
puts "Stop after #{max_consecutive_errors} consecutive errors.\n\n"

consecutive_errors = 0
summary = Hash.new(0)

(from..to).each do |number|
  property = Property.find_or_create_by!(
    year:, district:, tahsil:, village:, property_no: number
  )

  if property.found? && property.documents.exists?
    summary[:found] += 1
    consecutive_errors = 0
    puts "##{number} ... already found (#{property.documents.count} docs), skipping"
    next
  end

  print "##{number} ... "
  begin
    result = Igr::PropertyScraper.call(property)
    docs   = property.documents.count
    summary[result.status] += 1
    puts "#{result.status} (#{result.attempts} captcha attempts, #{docs} docs)"

    if result.status == :error
      consecutive_errors += 1
    else
      consecutive_errors = 0
    end
  rescue StandardError => e
    # PropertyScraper re-raises after marking the row :error.
    summary[:error] += 1
    consecutive_errors += 1
    puts "ERROR #{e.class}: #{e.message}"
  end

  if consecutive_errors >= max_consecutive_errors
    puts "\nStopping: #{consecutive_errors} consecutive errors at property ##{number}."
    break
  end
end

puts "\n=== Summary ==="
summary.each { |status, count| puts "  #{status}: #{count}" }
total_docs = Property.where(year:, district:, tahsil:, village:, property_no: from..to)
                     .joins(:documents).distinct.count
puts "  properties with documents: #{total_docs}"

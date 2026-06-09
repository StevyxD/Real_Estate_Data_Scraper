# Backfill building_name from the IndexII description (section 4) using the
# regex extractor, for documents that don't have one yet.
#
#   bin/rails runner script/backfill_building_name.rb
#
# Leaves already-populated names untouched (the LLM backfill may have improved
# them). For the messier rows this can't crack, run backfill_building_name_llm.rb.
updated = 0
scope = Document.where.not(index_ii: {}).where(building_name: [nil, ""])

scope.find_each do |document|
  name = Igr::BuildingName.call(document.index_ii["4"].to_s)
  next if name.blank?

  document.update_column(:building_name, name)
  updated += 1
end

puts "Backfilled building_name on #{updated} documents via the regex extractor."
puts "Remaining blank: #{Document.where.not(index_ii: {}).where(building_name: [nil, '']).count}"

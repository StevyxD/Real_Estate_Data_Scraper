# Backfill building_name from the IndexII description (section 4) using the
# regex extractor, for documents that don't have one yet.
#
#   bin/rails runner script/backfill_building_name.rb
#
# Leaves already-populated names untouched (the LLM backfill may have improved
# them). For the messier rows this can't crack, run backfill_building_name_llm.rb.
updated = 0
# Every doc without a name yet — sourced from building_description, which falls
# back to the grid Property Description, so un-enriched docs are covered too.
scope = Document.where(building_name: [nil, ""])

scope.find_each do |document|
  name = Igr::BuildingName.call(document.building_description.to_s)
  next if name.blank?

  document.update_column(:building_name, name)
  updated += 1
end

puts "Backfilled building_name on #{updated} documents via the regex extractor."
puts "Remaining blank: #{Document.where(building_name: [nil, '']).count}"

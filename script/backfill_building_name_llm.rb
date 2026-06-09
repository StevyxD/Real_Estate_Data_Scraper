# Fill building_name for the documents the regex extractor couldn't crack, using
# Claude Haiku. POST-scrape enrichment only — never run while a scrape is live
# (a second process contends with the scraper's Chrome).
#
#   ANTHROPIC_API_KEY=sk-ant-... bin/rails runner script/backfill_building_name_llm.rb
#
# Only touches regex-blank rows, batched (~5¢ per dataset). A null answer means
# the model judged there is genuinely no building (plot/correction deed).
scope = Document.where.not(index_ii: {}).where(building_name: [nil, ""])
documents = scope.to_a
puts "#{documents.size} documents need an LLM building name."

llm = Igr::BuildingNameLlm.new
filled = 0

documents.each_slice(Igr::BuildingNameLlm::BATCH_SIZE).with_index do |batch, i|
  descriptions = batch.map { |document| document.index_ii["4"].to_s }
  names = llm.call_batch(descriptions)

  batch.zip(names).each do |document, name|
    next if name.blank?

    document.update_column(:building_name, name)
    filled += 1
  end

  puts "  batch #{i + 1}: #{filled} filled so far"
end

puts "Done. Filled #{filled} of #{documents.size}."

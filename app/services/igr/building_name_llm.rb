require "anthropic"

module Igr
  # LLM fallback for the building-name extractor. The regex extractor
  # (Igr::BuildingName) is tuned for the rigid Kharghar format and misses the
  # messier Mumbai/Parel free-text (names with commas, "प्रिमायसेस नं" units, mill
  # compounds written in prose). This sends those leftovers to Claude Haiku.
  #
  # Haiku is a deliberate choice for this cheap, high-volume, simple extraction
  # (~5¢ per dataset, batched) — it is the model the project has always used for
  # this step. Run it as POST-scrape enrichment (see
  # script/backfill_building_name_llm.rb); it is NOT called during scraping.
  class BuildingNameLlm
    MODEL      = :"claude-haiku-4-5"
    MAX_TOKENS = 2048
    BATCH_SIZE = 25

    SYSTEM = <<~PROMPT.freeze
      You extract the society/building name from Marathi property descriptions
      taken from Maharashtra IGR (सूची क्र.2) registration records.

      Rules:
      - Return ONLY the building or society name, in the original Marathi script,
        exactly as it appears. You may drop a leading wing/flat/floor token.
      - If there is genuinely no building — a plot-only sale, a correction or
        reconveyance deed, agricultural land — return the single word NONE.
      - Never explain, never add punctuation or quotes around the name.
    PROMPT

    def self.call(description, client: nil)
      new(client:).call_batch([description]).first
    end

    def initialize(client: nil)
      @client = client || Anthropic::Client.new
    end

    # Returns an array of names (or nil) aligned 1:1 with +descriptions+.
    def call_batch(descriptions)
      descriptions.each_slice(BATCH_SIZE).flat_map { |slice| extract_slice(slice) }
    end

    private

    def extract_slice(slice)
      numbered = slice.each_with_index.map { |d, i| "#{i + 1}. #{one_line(d)}" }.join("\n")

      message = @client.messages.create(
        model: MODEL,
        max_tokens: MAX_TOKENS,
        system_: [{ type: "text", text: SYSTEM }],
        messages: [{ role: "user", content: <<~USER }]
          Extract the building/society name for each numbered description below.
          Reply with one line per item in the exact form "<number>: <name or NONE>".

          #{numbered}
        USER
      )

      parse(text_of(message), slice.size)
    end

    def text_of(message)
      message.content.select { |block| block.type == :text }.map(&:text).join("\n")
    end

    # Map "<n>: <name>" lines back onto the slice; NONE/blank -> nil.
    def parse(text, size)
      answers = Array.new(size)
      text.to_s.each_line do |line|
        m = line.match(/\A\s*(\d+)\s*[:.)\-]\s*(.*?)\s*\z/) or next

        index = m[1].to_i - 1
        next unless index.between?(0, size - 1)

        value = m[2].to_s.strip
        answers[index] = value unless value.empty? || value.casecmp?("NONE")
      end
      answers
    end

    def one_line(text)
      text.to_s.gsub(/\s+/, " ").strip
    end
  end
end

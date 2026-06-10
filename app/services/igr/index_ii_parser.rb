require "bigdecimal"
require "bigdecimal/util"
require "nokogiri"

module Igr
  # Parses the IndexII (सूची क्र.2) detail report.
  #
  # The report is a table of field rows: the first cell is "(N) <Marathi> (<English>)"
  # and the next cell holds the value. CRUCIALLY, the field LAYOUT differs by
  # document type — a mortgage notice has (2) Loan amount / (5) Mortgagor where a
  # sale deed has (2) Consideration / (7) Seller — so the live path maps by the
  # LABEL text, not the (N) number (#parse / #map_fields).
  #
  # The legacy #from_sections maps a {N => value} hash by number (the format the
  # recovered sale-deed data was stored in) and is unit-tested against that data.
  class IndexIiParser
    PAN_RE           = /[A-Z]{5}[0-9]{4}[A-Z]/
    PINCODE_LABEL_RE = /(?:पिन\s*कोड|pin\s*code|pincode)\s*[:\-]*\s*(\d{6})/i
    PINCODE_CITY_RE  = /(?:नवी\s*मुंबई|मुंबई)[^\d]{0,25}(4\d{5})/
    PINCODE_ANY_RE   = /\b(4\d{5})\b/
    UNIT_NO_RE = /(?:सदनिका|फ्लॅट|दुकान|गाळा|गाला|युनिट|ऑफिस|flat|shop|unit|office|gala)\s*(?:नं|क्र|no)?\.?\s*[:\-]?\s*([\w\/]+)/i
    FLOOR_RE   = /([^\s,][^,]*?)\s*मजला/
    WING_RE    = /([^\s,][^,]*?)\s*(?:विंग|टॉवर|wing|tower)/i
    CTS_RE     = /C\.?\s*T\.?\s*S\.?\s*(?:Number|No|नं|क्र)?\s*[:\-]?\s*([\d\/,\s]+?)\s*[;)]/i

    # A field row's first cell, e.g. "(2) कर्जाची रक्कम (Loan amount)".
    FIELD_RE = /\A\(\s*(\d{1,2})\s*\)\s*(.*)/m
    # Labels identifying a party (executant / claimant / mortgagor / mortgagee …).
    PARTY_RE = /नाव व पत्ता|mortgagor|mortgagee|\bseller\b|\bpurchaser\b|लिहून\s*(?:देणार|घेणार)|कर्ज\s*(?:घेणाऱ्या|देणाऱ्या)|claimant|executant/i

    Result = Struct.new(:attrs, :sections, keyword_init: true)

    def self.parse(html)
      new.parse(html)
    end

    def self.from_sections(sections)
      new.from_sections(sections)
    end

    # Live path: parse the report table, mapping by label. +sections+ still stores
    # {N => value} as a raw backup (jsonb).
    def parse(html)
      return from_sections(html) if html.is_a?(Hash)

      doc = html.is_a?(Nokogiri::XML::Node) ? html : Nokogiri::HTML(html.to_s)
      fields = extract_fields(doc)
      sections = fields.each_with_object({}) { |f, acc| acc[f[:num]] = f[:value] }
      Result.new(attrs: map_fields(fields), sections: sections)
    end

    # Legacy number-keyed path (recovered sale-deed data + tests).
    def from_sections(sections)
      s = stringify(sections)
      desc = s["4"].to_s
      area = s["5"].to_s.strip

      attrs = {
        doc_type:             presence(s["1"]),
        consideration_amount: to_amount(s["2"]),
        market_value:         to_amount(s["3"]),
        property_description: presence(desc),
        area:                 presence(area),
        area_unit:            area_unit(area),
        area_sqft:            area_number(area),
        seller_pan:           s["7"].to_s[PAN_RE],
        purchaser_pan:        s["8"].to_s[PAN_RE],
        execution_date:       to_date(s["9"]),
        registration_date:    to_date(s["10"]),
        stamp_duty:           to_amount(s["12"]),
        registration_fee:     to_amount(s["13"]),
        building_name:        Igr::BuildingName.call(desc),
        unit_no:              capture(desc, UNIT_NO_RE),
        floor:                capture(desc, FLOOR_RE),
        tower_wing:           capture(desc, WING_RE),
        cts_number:           capture(desc, CTS_RE),
        pincode:              pincode_from(desc)
      }.compact

      Result.new(attrs: attrs, sections: s)
    end

    private

    # [{num:, label:, value:}] for each "(N) …" row in the report.
    def extract_fields(doc)
      doc.css("tr").filter_map do |tr|
        cells = tr.css("td").map { |td| clean(td.text) }.reject(&:empty?)
        next if cells.size < 2

        m = cells.first.match(FIELD_RE) or next
        { num: m[1], label: m[2].to_s, value: cells[1].to_s }
      end
    end

    def map_fields(fields)
      attrs = {}
      parties = []

      fields.each do |field|
        if PARTY_RE.match?(field[:label])
          parties << field[:value]
        else
          apply_field(attrs, field[:label], field[:value])
        end
      end

      # Party blocks in document order: 1st -> seller side, 2nd -> purchaser side.
      attrs[:seller_pan]    ||= parties[0].to_s[PAN_RE] if parties[0]
      attrs[:purchaser_pan] ||= parties[1].to_s[PAN_RE] if parties[1]

      desc = attrs[:property_description].to_s
      attrs[:building_name] ||= Igr::BuildingName.call(desc)
      attrs[:unit_no]       ||= capture(desc, UNIT_NO_RE)
      attrs[:floor]         ||= capture(desc, FLOOR_RE)
      attrs[:tower_wing]    ||= capture(desc, WING_RE)
      attrs[:cts_number]    ||= capture(desc, CTS_RE)
      attrs[:pincode]       ||= pincode_from(desc)
      attrs.compact
    end

    # We deliberately do NOT map the document type or party NAMES here — the
    # results grid already provides cleaner values for those, and IndexII merges
    # over the grid in PropertyScraper.
    def apply_field(attrs, label, value)
      case label
      when label_re("consideration", "मोबदला", "loan amount", "कर्जाची रक्कम")
        attrs[:consideration_amount] = to_money(value)
      when label_re("market value", "बाजार ?भाव")
        attrs[:market_value] = to_money(value)
      when label_re("property description", "भू-मापन", "घरक्रमांक")
        attrs[:property_description] = presence(value)
      when label_re("\\(area\\)", "क्षेत्रफळ")
        attrs.merge!(parse_area(value))
      when label_re("stamp duty", "मुद्रांक")
        attrs[:stamp_duty] = to_money(value)
      when label_re("registration fee", "filing amount", "फायलींग शुल्क", "नोंदणी (?:फी|शुल्क)")
        attrs[:registration_fee] = to_money(value)
      when label_re("date of registration", "नोंदणीचा दिनांक", "date of filing", "नोटीस फाईल")
        attrs[:registration_date] ||= to_date(value)
      when label_re("date of execution", "date of mortgage", "गहाण", "submission", "करार दिनांक")
        attrs[:execution_date] ||= to_date(value)
      end
    end

    def label_re(*words)
      Regexp.union(words.map { |w| Regexp.new(w, Regexp::IGNORECASE) })
    end

    def stringify(sections)
      (sections || {}).transform_keys(&:to_s)
    end

    # Strict: only a bare number (legacy path — lease-rent/multi-property text in
    # a value section must not be mistaken for an amount).
    def to_amount(value)
      text = value.to_s.strip
      return nil unless text.match?(/\A-?[\d,]+(?:\.\d+)?\z/)

      text.delete(",").to_d
    end

    # Lenient: pull the number out of a known-amount field ("Rs.2000000/-").
    def to_money(value)
      cleaned = value.to_s.gsub(/rs\.?|\/-|,/i, "")
      m = cleaned.match(/-?\d+(?:\.\d+)?/) or return nil

      m[0].to_d
    end

    def to_date(value)
      m = value.to_s.match(%r{(\d{2})/(\d{2})/(\d{4})}) or return nil

      Date.new(m[3].to_i, m[2].to_i, m[1].to_i)
    rescue ArgumentError
      nil
    end

    # "1) Carpet Area :25.09 Square Meter" -> number + unit next to the unit word.
    def parse_area(value)
      m = value.match(/([\d,]+(?:\.\d+)?)\s*(square\s*met\w*|sq\.?\s*m\w*|square\s*f\w*|sq\.?\s*f\w*|चौ\.?\s*(?:मीटर|मी|फूट|फु)\w*)/i)
      return { area: presence(value) } unless m

      {
        area:      presence(value.sub(/\A\s*\d+\)\s*/, "")),
        area_sqft: m[1].delete(",").to_d,
        area_unit: normalize_unit(m[2])
      }
    end

    def normalize_unit(unit)
      return "चौ.मीटर" if /met|मीटर|मी/i.match?(unit)
      return "चौ.फूट"  if /f(ee|oo)t|फूट|फु/i.match?(unit)

      presence(unit)
    end

    # Legacy area parsing (value is already "<number> <unit>").
    def area_number(area)
      m = area.to_s.match(/([\d,]+(?:\.\d+)?)/) or return nil

      m[1].delete(",").to_d
    end

    def area_unit(area)
      presence(area.to_s.sub(/\A[\d.,\s]+/, "").strip)
    end

    def pincode_from(text)
      str = text.to_s
      if (m = str.match(PINCODE_LABEL_RE)) then m[1]
      elsif (m = str.match(PINCODE_CITY_RE)) then m[1]
      elsif (m = str.match(PINCODE_ANY_RE)) then m[1]
      end
    end

    def capture(text, regex)
      m = text.to_s.match(regex) or return nil

      presence(m[1].to_s.gsub(/\s+/, " ").strip)
    end

    def clean(text)
      text.to_s.gsub(/[[:space:]]+/, " ").strip
    end

    def presence(value)
      value.to_s.strip.empty? ? nil : value.to_s.strip
    end
  end
end

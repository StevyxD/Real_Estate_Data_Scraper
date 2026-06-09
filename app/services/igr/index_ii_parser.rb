require "bigdecimal"
require "bigdecimal/util"
require "nokogiri"

module Igr
  # Parses the IndexII (सूची क्र.2) detail report. The report is a numbered form;
  # the original scraper keys each field by its "(N)" number, which is what the
  # +index_ii+ jsonb stores. Verified field map:
  #   (1)  document type            (2)  consideration / मोबदला
  #   (3)  market value             (4)  property description (unit/floor/area)
  #   (5)  area (e.g. "91.15 चौ.मीटर")
  #   (7)  seller party block       (8)  purchaser party block  -- PAN in each
  #   (9)  execution date           (10) registration date
  #   (11) doc-no/year              (12) stamp duty             (13) registration fee
  #
  # +from_sections+ (the numbered-hash -> attributes mapping) is exact and is
  # unit-tested against the recovered data. +parse+ first extracts that hash
  # from the live report HTML; that DOM walk is best-effort and should be
  # re-verified against the live page (see #extract_sections).
  class IndexIiParser
    PAN_RE     = /[A-Z]{5}[0-9]{4}[A-Z]/
    PINCODE_LABEL_RE = /(?:पिन\s*कोड|pin\s*code|pincode)\s*[:\-]*\s*(\d{6})/i
    PINCODE_CITY_RE  = /(?:नवी\s*मुंबई|मुंबई)[^\d]{0,25}(4\d{5})/
    UNIT_NO_RE = /(?:सदनिका|फ्लॅट|दुकान|गाळा|गाला|युनिट|ऑफिस)\s*(?:नं|क्र|no)?\.?\s*([\w\/\-]+)/i
    FLOOR_RE   = /([^\s,][^,]*?)\s*मजला/
    WING_RE    = /([^\s,][^,]*?)\s*(?:विंग|टॉवर|wing|tower)/i
    CTS_RE     = /C\.?\s*T\.?\s*S\.?\s*(?:Number|No|नं|क्र)?\s*[:\-]?\s*([\d\/,\s]+?)\s*[;)]/i

    Result = Struct.new(:attrs, :sections, keyword_init: true)

    def self.parse(html)
      new.parse(html)
    end

    def self.from_sections(sections)
      new.from_sections(sections)
    end

    def parse(html)
      from_sections(extract_sections(html))
    end

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

    # Best-effort extraction of the numbered sections from the live report HTML.
    # The सूची क्र.2 report renders each field's value in its own cell; we collect
    # non-empty cell texts in document order. VERIFY against the live page before
    # trusting the live path — the mapping (from_sections) is the tested part.
    def extract_sections(html)
      return html if html.is_a?(Hash)

      doc = html.is_a?(Nokogiri::XML::Node) ? html : Nokogiri::HTML(html.to_s)
      values = doc.css("td, span").map { |n| n.text.to_s.gsub(/[[:space:]]+/, " ").strip }
                  .reject(&:empty?)
      values.each_with_index.to_h { |text, i| [(i + 1).to_s, text] }
    end

    def stringify(sections)
      (sections || {}).transform_keys(&:to_s)
    end

    # Only parse a section that is essentially a bare number. Lease-rent
    # schedules and multi-property blocks land in the value/area sections too,
    # and must NOT be mistaken for an amount.
    def to_amount(value)
      text = value.to_s.strip
      return nil unless text.match?(/\A-?[\d,]+(?:\.\d+)?\z/)

      text.delete(",").to_d
    end

    def to_date(value)
      m = value.to_s.match(%r{(\d{2})/(\d{2})/(\d{4})}) or return nil

      Date.new(m[3].to_i, m[2].to_i, m[1].to_i)
    rescue ArgumentError
      nil
    end

    def area_number(area)
      m = area.to_s.match(/([\d,]+(?:\.\d+)?)/) or return nil

      m[1].delete(",").to_d
    end

    def area_unit(area)
      unit = area.to_s.sub(/\A[\d.,\s]+/, "").strip
      presence(unit)
    end

    def pincode_from(text)
      if (m = text.to_s.match(PINCODE_LABEL_RE))
        m[1]
      elsif (m = text.to_s.match(PINCODE_CITY_RE))
        m[1]
      end
    end

    def capture(text, regex)
      m = text.to_s.match(regex) or return nil

      presence(m[1].to_s.gsub(/\s+/, " ").strip)
    end

    def presence(value)
      value.to_s.strip.empty? ? nil : value.to_s.strip
    end
  end
end

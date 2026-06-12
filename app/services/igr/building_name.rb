module Igr
  # Extracts the society/building name out of the Marathi property description
  # (IndexII section 4). The description appears in two shapes:
  #   - comma-separated: "सदनिका नं. 1101,अकरावा मजला,क्रिस्टल कॉर्नर,प्लॉट नं. 110,..."
  #   - free space-separated: "सदनिका क 1703 17 वा मजला किस्टोन एलिटा सी एच एस लि प्लॉट नं 49 ..."
  # In both, the building name sits AFTER the floor marker (मजला/माळा) and BEFORE
  # the next locality token (प्लॉट/सेक्टर/मौजे/...). Commas are normalised to
  # spaces so a single marker-based pass handles both shapes.
  #
  # Deliberately conservative: returns nil for plot-only sales and correction /
  # reconveyance deeds (no building), so the UI falls back to "Property #N". The
  # messier Mumbai mill-compound free-text that this misses is covered by
  # Igr::BuildingNameLlm.
  class BuildingName
    LABEL_RE = /(?:इमारतीचे\s*नाव|इमारतीचेनाव|बिल्डिंग\s*चे\s*नाव|बिल्डिंगचे\s*नाव|building\s*name)\s*[:\-]?\s*/i
    FLOOR_RE = /(?:मजला|माळा)/
    UNIT_RE  = %r{(?:सदनिका|फ्लॅट|दुकान|गाळा|गाला|युनिट|ऑफिस|शॉप|प्रिमायसेस)\s*(?:नं|क्र|no)?\.?\s*[\w/\-]*}i

    # Tokens that end a building name (or never belong to one).
    STOP_RE = %r{प्लॉट|प्लाट|सेक्टर|मौजे|गाव|ता\.|तालुका|जि\.|जिल्हा|रोड|मार्ग|
                 सि\.?\s*एस|सीटीएस|c\.?\s*t\.?\s*s|गट\s*नं|सर्व्हे|सर्वे|
                 नवी\s*मुंबई|मुंबई|पिन\s*कोड|पिनकोड|रेरा|चटई|क्षेत्र|चौ\.|दर\s|\(}xi

    def self.call(description)
      new(description).call
    end

    def initialize(description)
      @raw  = description.to_s
      @text = @raw.tr(",", " ").gsub(/\s+/, " ").strip
    end

    def call
      from_label || from_structure
    end

    private

    # After an explicit "Building Name:" / "इमारतीचे नाव:" label, take the text up
    # to the next address field (English or Marathi), preserving commas in a
    # multi-part society name like "ISHAN APARTMENT, PRABODHAN SRA CHS LTD".
    LABEL_STOP_RE = %r{,?\s*(?:flat\s*no|room\s*no|floor\s*no|wing|road|block|sector|
                       landmark|plot\s*(?:no|number)|final\s*plot|pin\s*code|city|
                       state|district|other\s*details)\b|[;]|\d{6}|
                       [,\s](?:विंग|वींग)(?=[\s,]|\z)|ब्लॉक|प्लॉट|सेक्टर|मौजे|रोड|पिन}xi

    def from_label
      m = @raw.match(LABEL_RE) or return nil

      name = @raw[m.end(0)..].to_s
                 .split(LABEL_STOP_RE, 2).first.to_s
                 .gsub(/\s+/, " ").strip
                 .sub(/[,\-–—:;]+\z/, "").strip
      plausible?(name) ? name : nil
    end

    def from_structure
      body = @text
      body = body.split(/इतर\s*माहिती\s*:/, 2).last.to_s if body =~ /इतर\s*माहिती\s*:/

      tail =
        if (floor = body.match(FLOOR_RE))
          body[floor.end(0)..]
        elsif (unit = body.match(UNIT_RE))
          body[unit.end(0)..]
        end

      tail ? candidate(tail) : nil
    end

    # Text up to the first stop token, cleaned; accepted only if it looks like
    # a name.
    def candidate(text)
      name = text.to_s.split(STOP_RE, 2).first.to_s.gsub(/\s+/, " ").strip
      name = name.sub(/\A\S{1,3}\s*-?\s*(?:विंग|wing)\s+/i, "") # drop a leading "B विंग"/"डी-विंग"
                 .strip
                 .sub(/[-–—:,;]+\z/, "").strip
      plausible?(name) ? name : nil
    end

    def plausible?(name)
      return false unless name.length.between?(3, 60)
      return false unless name.match?(/\p{L}/) # must contain a letter (any script)

      true
    end
  end
end

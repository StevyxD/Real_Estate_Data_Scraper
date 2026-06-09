require "nokogiri"

module Igr
  # Parses the IGR results grid (table#RegistrationGrid) into one Row per
  # registration. Verified live Mumbai headers:
  #   DocNo  DName  RDate  SROName  Seller Name  Purchaser Name
  #   Property Description  SROCode  Status  IndexII
  # (DName is the document type.) The GridView appends pager/footer rows with a
  # different cell count and a nested page-link table, so rows whose cell count
  # != header count are skipped.
  class ResultParser
    GRID_SELECTORS = ["table#RegistrationGrid", "table[id$='RegistrationGrid']"].freeze

    # normalized header text => Document attribute
    HEADER_MAP = {
      "docno"                => :doc_number,
      "dname"                => :doc_type,
      "rdate"                => :registration_date,
      "sroname"              => :sro_name,
      "srocode"              => :sro_code,
      "seller name"          => :seller_names,
      "purchaser name"       => :purchaser_names,
      "property description" => :property_description
    }.freeze

    # row_index is the 0-based index among data rows; the IndexII link uses it
    # (__doPostBack('RegistrationGrid','indexII$<row_index>')).
    Row = Struct.new(:row_index, :attrs, :raw, keyword_init: true)

    def self.parse(html)
      new(html).parse
    end

    def initialize(html)
      @doc = html.is_a?(Nokogiri::XML::Node) ? html : Nokogiri::HTML(html.to_s)
    end

    def parse
      grid = find_grid or return []
      trs = grid.css("tr")
      return [] if trs.empty?

      headers = cells(trs.first).map { |c| normalize(c.text) }
      return [] if headers.none? { |h| HEADER_MAP.key?(h) }

      index = 0
      trs.drop(1).filter_map do |tr|
        tds = cells(tr)
        next if tds.size != headers.size # pager/footer row

        row = build_row(headers, tds, index)
        index += 1
        row
      end
    end

    private

    def build_row(headers, tds, index)
      raw = {}
      attrs = {}
      headers.each_with_index do |header, i|
        text = clean(tds[i].text) # preserve case for values
        raw[header] = text unless header.empty?
        next unless (field = HEADER_MAP[header])

        attrs[field] = field == :registration_date ? parse_date(text) : presence(text)
      end
      Row.new(row_index: index, attrs: attrs, raw: raw)
    end

    def find_grid
      GRID_SELECTORS.each do |selector|
        node = @doc.at_css(selector)
        return node if node
      end
      nil
    end

    # Direct children only, so nested tables in pager rows don't leak cells.
    def cells(tr)
      tr.xpath("./th | ./td")
    end

    def normalize(text)
      clean(text).downcase
    end

    def clean(text)
      text.to_s.gsub(/[[:space:]]+/, " ").strip
    end

    def presence(text)
      text.to_s.strip.empty? ? nil : text.strip
    end

    def parse_date(text)
      return nil if text.to_s.strip.empty?

      Date.strptime(text.strip, "%d/%m/%Y")
    rescue ArgumentError
      nil
    end
  end
end

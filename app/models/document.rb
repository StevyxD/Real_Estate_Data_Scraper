# One registration record scraped from the IGR results grid for a Property and
# enriched from its IndexII (सूची क्र.2) detail report.
#
# +raw+ holds the original grid row (keyed by lowercased header: dname, docno,
# rdate, "seller name", ...). +index_ii+ holds the numbered IndexII sections
# ("1".."14"). Marathi is the source language; the UI offers an EN toggle.
class Document < ApplicationRecord
  belongs_to :property

  # Square-metre area converted to square feet for the per-sqft rate.
  SQM_TO_SQFT = 10.7639

  # Locality -> pincode. Only add a village once its records agree on ONE value;
  # a pincode literally printed on the IndexII page always wins over inference.
  VILLAGE_PINCODES = {
    "Kharghar" => "410210"
  }.freeze

  # doc_type (Marathi/English) -> coarse transaction category for the card badge.
  # Checked top to bottom; the broad "sale" bucket is last so the more specific
  # instruments (lease, gift, mortgage, ...) win first.
  SALE_TYPE_RULES = [
    [:lease,         ["लिव्ह अॅड लायसन्स", "leave and licens", "लीज", "लिज", "लायसन्स"]],
    [:redevelopment, ["पर्यायी जागेचा", "पुनर्विकास", "विकास करार"]],
    [:gift,          ["बक्षीस"]],
    [:mortgage,      ["गहाण", "मॉरगेज", "मॉर्गेज", "mortgage"]],
    [:release,       ["रिलीज", "रिकन्व्हेन्स", "reconvey", "release"]],
    [:correction,    ["चुक दुरुस्ती", "दुरुस्ती", "कन्फर्मेशन", "confirmation"]],
    [:sale,          ["सेल डीड", "अभिहस्तांतरण", "करारनामा", "अँग्रीमेंट", "अॅग्रीमेंट",
                      "ट्रान्सफर", "transfer", "खरेदी", "sale", "deed"]]
  ].freeze

  before_save :infer_pincode_from_village
  before_save :build_search_key

  scope :enriched,   -> { where(index_ii_fetched: true) }
  scope :with_price, -> { where.not(consideration_amount: [nil, 0]) }
  scope :recent,     -> { order(registration_date: :desc) }

  # Card title: prefer the extracted society/building name, else a stable label.
  def display_title
    building_name.presence || "Property ##{property.property_no}"
  end

  def sellers
    split_parties(seller_names)
  end

  def purchasers
    split_parties(purchaser_names)
  end

  # Coarse transaction type symbol (see SALE_TYPE_RULES). Presentation of the
  # label/colour lives in DocumentsHelper#doc_sale_type.
  def sale_category
    text = doc_type.to_s.downcase
    SALE_TYPE_RULES.each do |category, keywords|
      return category if keywords.any? { |k| text.include?(k.downcase) }
    end
    :other
  end

  # Carpet area normalised to square feet (areas are recorded in चौ.मीटर or चौ.फूट).
  def carpet_sqft
    return nil if area_sqft.blank? || area_sqft.zero?

    if /मीटर|meter|sq\.?\s*m/i.match?(area_unit.to_s)
      area_sqft * SQM_TO_SQFT
    else
      area_sqft
    end
  end

  # ₹ per sq.ft on consideration value, or nil when either side is unknown.
  def rate_per_sqft
    return nil if consideration_amount.blank? || consideration_amount.zero?

    sqft = carpet_sqft
    return nil if sqft.blank? || sqft.zero?

    (consideration_amount / sqft).round
  end

  private

  # Parties are stored as a Postgres-array-ish literal: {"name a","name b"}.
  def split_parties(value)
    return [] if value.blank?

    value.to_s
         .sub(/\A\{/, "").sub(/\}\z/, "")
         .scan(/"([^"]*)"|([^,]+)/)
         .map { |quoted, bare| (quoted || bare).to_s.strip }
         .reject(&:blank?)
  end

  def infer_pincode_from_village
    return if pincode.present?

    self.pincode = VILLAGE_PINCODES[property&.village]
  end

  # English-friendly phonetic index of the searchable text (see Igr::SearchKey).
  def build_search_key
    self.search_key = Igr::SearchKey.for_document(self)
  end
end

module DocumentsHelper
  # sale_category -> [label, tailwind badge classes]
  SALE_BADGES = {
    sale:          ["Sale",           "bg-emerald-50 text-emerald-700 ring-1 ring-emerald-600/20"],
    lease:         ["Leave & License", "bg-sky-50 text-sky-700 ring-1 ring-sky-600/20"],
    gift:          ["Gift",           "bg-pink-50 text-pink-700 ring-1 ring-pink-600/20"],
    mortgage:      ["Mortgage",       "bg-amber-50 text-amber-700 ring-1 ring-amber-600/20"],
    release:       ["Release",        "bg-violet-50 text-violet-700 ring-1 ring-violet-600/20"],
    redevelopment: ["Redevelopment",  "bg-indigo-50 text-indigo-700 ring-1 ring-indigo-600/20"],
    correction:    ["Correction",     "bg-slate-100 text-slate-600 ring-1 ring-slate-500/20"],
    other:         ["Document",       "bg-slate-100 text-slate-600 ring-1 ring-slate-500/20"]
  }.freeze

  def doc_sale_type(document)
    SALE_BADGES.fetch(document.sale_category, SALE_BADGES[:other])
  end

  def rate_per_sqft_label(document)
    rate = document.rate_per_sqft
    rate && "₹#{number_with_delimiter(rate)}/sq.ft"
  end

  def carpet_label(document)
    sqft = document.carpet_sqft
    sqft ? "#{number_with_delimiter(sqft.round)} sq.ft" : "—"
  end

  # The headline price: consideration if there is one, else market value.
  def headline_price(document)
    if document.consideration_amount.to_f.positive?
      [document.consideration_amount, "Consideration"]
    else
      [document.market_value, "Market value"]
    end
  end

  def party_summary(names, max: 2)
    return "—" if names.blank?

    shown = names.first(max).join(", ")
    names.size > max ? "#{shown} +#{names.size - max}" : shown
  end

  def sort_options
    [
      ["Most recent", "recent"],
      ["Oldest first", "oldest"],
      ["Price: high to low", "price_high"],
      ["Price: low to high", "price_low"],
      ["Largest area", "area"]
    ]
  end
end

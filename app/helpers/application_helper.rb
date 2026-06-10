module ApplicationHelper
  include Pagy::Frontend

  CRORE = 1_00_00_000
  LAKH  = 1_00_000

  # Compact Indian-style amount: ₹1.61 Cr, ₹85.5 Lac, ₹9.2 K, ₹0.
  def inr_short(amount)
    return "—" if amount.nil?

    number = amount.to_f
    return "₹0" if number.zero?

    if number >= CRORE
      "₹#{trim(number / CRORE)} Cr"
    elsif number >= LAKH
      "₹#{trim(number / LAKH)} Lac"
    elsif number >= 1_000
      "₹#{trim(number / 1_000)} K"
    else
      "₹#{number.round}"
    end
  end

  # Full amount with Indian digit grouping: ₹1,61,47,750.
  def inr_indian(amount)
    return "—" if amount.nil?

    digits = amount.to_i.abs.to_s
    return "₹#{digits}" if digits.length <= 3

    head = digits[0...-3].reverse.scan(/\d{1,2}/).join(",").reverse
    "₹#{head},#{digits[-3..]}"
  end

  # search_status -> badge label + tailwind classes (+ a live dot for "scraping").
  PROPERTY_STATUS = {
    "scraping" => { label: "Scraping",   classes: "bg-blue-50 text-blue-700 ring-1 ring-blue-600/20",     live: true },
    "pending"  => { label: "Queued",     classes: "bg-slate-100 text-slate-600 ring-1 ring-slate-500/20" },
    "found"    => { label: "Scraped",    classes: "bg-emerald-50 text-emerald-700 ring-1 ring-emerald-600/20" },
    "empty"    => { label: "No records", classes: "bg-amber-50 text-amber-700 ring-1 ring-amber-600/20" },
    "error"    => { label: "Failed",     classes: "bg-rose-50 text-rose-700 ring-1 ring-rose-600/20" }
  }.freeze

  def property_status(property)
    PROPERTY_STATUS.fetch(property.search_status, PROPERTY_STATUS["pending"])
  end

  def property_status_badge(property)
    status = property_status(property)
    dot = if status[:live]
      tag.span("", class: "mr-1 inline-block h-1.5 w-1.5 animate-ping rounded-full bg-blue-500")
    else
      "".html_safe
    end
    tag.span(safe_join([dot, status[:label]]),
             class: "inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-medium #{status[:classes]}")
  end

  def ago(time)
    time ? "#{time_ago_in_words(time)} ago" : "—"
  end

  private

  # Round to 2 decimals and drop trailing zeros: 1.61 -> "1.61", 2.0 -> "2".
  def trim(value)
    rounded = value.round(2)
    rounded == rounded.to_i ? rounded.to_i.to_s : format("%.2f", rounded).sub(/\.?0+\z/, "")
  end
end

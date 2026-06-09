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

  private

  # Round to 2 decimals and drop trailing zeros: 1.61 -> "1.61", 2.0 -> "2".
  def trim(value)
    rounded = value.round(2)
    rounded == rounded.to_i ? rounded.to_i.to_s : format("%.2f", rounded).sub(/\.?0+\z/, "")
  end
end

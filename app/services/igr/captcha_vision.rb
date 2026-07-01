require "anthropic"
require "base64"

module Igr
  # Claude-vision fallback for the 6-char hex captcha. Used by
  # Session#read_captcha ONLY after the free Tesseract OCR has missed a few times
  # (see Session::VISION_AFTER_MISSES) — most captchas never reach it. Reading six
  # hex glyphs is trivial for a vision model and far more reliable than OCR on the
  # noisier images, so it collapses the slowest part of a scrape: the wrong-captcha
  # retry loop.
  #
  # Haiku is the deliberate choice — cheap, vision-capable, and the family this
  # project already uses for the building-name fallback. Vision is OPTIONAL: with
  # no ANTHROPIC_API_KEY the scraper stays OCR-only (see +available?+), so nothing
  # breaks when the key is absent.
  module CaptchaVision
    MODEL      = :"claude-haiku-4-5"
    MAX_TOKENS = 16

    PROMPT = <<~TXT.freeze
      This image is a 6-character CAPTCHA. The characters are HEXADECIMAL only:
      digits 0-9 and the letters A-F (uppercase). Reply with ONLY those 6
      characters — no spaces, no punctuation, no explanation.
    TXT

    module_function

    # @return [Boolean] whether the vision fallback can run (an API key is set).
    def available?
      ENV["ANTHROPIC_API_KEY"].present?
    end

    # @param image [String] a data: URL (canvas toDataURL), bare base64, or raw
    #   PNG/JPEG bytes — same shapes Igr::Captcha accepts.
    # @return [String] the cleaned uppercase-hex guess (may be empty on a bad read
    #   or any API error; the caller just falls back to OCR / retries).
    def solve(image, client: nil)
      client ||= Anthropic::Client.new
      message = client.messages.create(
        model: MODEL,
        max_tokens: MAX_TOKENS,
        messages: [{ role: "user", content: [
          { type: "image", source: { type: "base64", media_type: "image/png", data: to_base64(image) } },
          { type: "text", text: PROMPT }
        ] }]
      )
      text_of(message).strip.upcase.gsub(/[^0-9A-F]/, "")
    rescue StandardError => e
      Rails.logger.warn("[igr] captcha vision failed: #{e.class}: #{e.message}")
      ""
    end

    # The captcha is captured as a PNG data: URL (Session#capture_captcha draws the
    # <img> to a canvas and reads toDataURL('image/png')), so PNG is the right
    # media_type for the common path.
    def to_base64(image)
      data = image.to_s
      if data.start_with?("data:")
        data.split(",", 2).last.to_s
      elsif data.start_with?("\x89PNG".b) || data.start_with?("\xFF\xD8".b)
        Base64.strict_encode64(data)
      else
        data # already base64
      end
    end

    def text_of(message)
      message.content.select { |block| block.type == :text }.map(&:text).join
    end
  end
end

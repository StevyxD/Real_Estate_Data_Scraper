require "base64"
require "tempfile"
require "mini_magick"
require "rtesseract"

module Igr
  # Solves the IGR portal's 6-character captcha (chars 0-9 and A-F only).
  #
  # Hard-won OCR facts (verified against the live site):
  # - The alphabet is HEXADECIMAL, not full A-Z. Restricting Tesseract to the
  #   hex whitelist is the single biggest accuracy lever — it stops the common
  #   S->5 / O->0 / Z->2 misreads.
  # - Grayscale + normalize + upscale ONLY. Do NOT -threshold the image: it
  #   hollows out the clean dark-green-on-light glyphs and wrecks accuracy.
  # - The captcha answer is NOT leakable (the Handler.ashx token is a one-time
  #   server-side lookup), so OCR is genuinely required.
  class Captcha
    WHITELIST = "0123456789ABCDEF"
    LENGTH    = 6

    def self.solve(image)
      new(image).solve
    end

    # +image+ may be a data: URL (canvas toDataURL), a bare base64 string, or
    # raw image bytes.
    def initialize(image)
      @image = image
    end

    # Returns the cleaned uppercase-hex guess. May be shorter than LENGTH on a
    # bad read; the caller just retries against a freshly regenerated captcha.
    def solve
      png = decode(@image)
      result = nil
      Tempfile.create(["captcha", ".png"], binmode: true) do |raw|
        raw.write(png)
        raw.flush
        processed = preprocess(raw.path)
        begin
          result = ocr(processed)
        ensure
          File.unlink(processed) if processed && File.exist?(processed)
        end
      end
      result
    end

    def self.valid?(text)
      text.to_s.match?(/\A[0-9A-F]{#{LENGTH}}\z/)
    end

    private

    def decode(image)
      data = image.to_s
      data = data.split(",", 2).last.to_s if data.start_with?("data:")
      return data if data.start_with?("\x89PNG".b) || data.start_with?("\xFF\xD8".b)

      Base64.decode64(data)
    end

    # Grayscale + normalize + upscale. No threshold (see class docs).
    def preprocess(path)
      out = "#{path}.proc.png"
      image = MiniMagick::Image.open(path)
      image.combine_options do |c|
        c.colorspace "Gray"
        c.normalize
        c.resize "300%"
      end
      image.write(out)
      out
    end

    def ocr(path)
      raw = RTesseract.new(path,
                           psm: 7,                  # treat as a single text line
                           oem: 3,
                           tessedit_char_whitelist: WHITELIST).to_s
      raw.strip.upcase.gsub(/[^0-9A-F]/, "")
    end
  end
end

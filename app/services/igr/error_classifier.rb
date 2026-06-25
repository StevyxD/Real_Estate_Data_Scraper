module Igr
  # Decides whether a failed scrape was the *site's* fault (it's down / throttled
  # / timing out — an "outage", retry soon and DON'T count it against the
  # property) or specific to *this* property (an "app" error — count it; give up
  # after MAX_ATTEMPTS). When in doubt we assume :outage, because the IGR portal
  # being slow/unavailable is by far the common failure and we'd rather keep
  # retrying than prematurely bury a real target.
  module ErrorClassifier
    module_function

    # Substrings that mean "the portal/network is unavailable", not "this
    # property is broken". Matched case-insensitively against the message.
    OUTAGE_PATTERNS = [
      "timeout", "timed out", "err_timed_out", "err_connection",
      "err_name_not_resolved", "err_internet_disconnected", "net::err",
      "this site can", "connection refused", "connection reset",
      "could not load", "service unavailable", "503", "502", "504",
      "bad gateway", "gateway timeout", "econnrefused", "econnreset",
      "session not created", "disconnected", "no such window",
      "chrome not reachable", "renderer", "tab crashed"
    ].freeze

    # Error classes that are always treated as an outage regardless of message.
    OUTAGE_CLASSES = %w[
      Selenium::WebDriver::Error::TimeoutError
      Net::OpenTimeout Net::ReadTimeout
      Errno::ECONNREFUSED Errno::ECONNRESET Errno::ETIMEDOUT
      SocketError
    ].freeze

    # @return [:outage, :app]
    def kind(error)
      return :outage if OUTAGE_CLASSES.include?(error.class.name)

      haystack = "#{error.class.name} #{error.message}".downcase
      return :outage if OUTAGE_PATTERNS.any? { |p| haystack.include?(p) }

      :app
    end

    def outage?(error)
      kind(error) == :outage
    end
  end
end

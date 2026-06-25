require "net/http"

module Igr
  # A cheap "is the IGR portal reachable right now?" probe used by the dispatcher
  # to decide whether to resume after a suspected outage — WITHOUT launching a
  # full headless-Chrome scrape just to find out the site is still down.
  module SiteHealth
    module_function

    URL     = Igr::Session::BASE_URL
    TIMEOUT = 10 # seconds

    # @return [Boolean] true if the portal answered with an HTTP response.
    # Any response (even a 500) means the host is up; only connection/timeout
    # errors count as "down".
    def up?
      uri = URI(URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT
      response = http.head(uri.path.presence || "/")
      response.code.to_i.positive?
    rescue StandardError => e
      Rails.logger.info("[igr] site health probe failed: #{e.class}: #{e.message}")
      false
    end
  end
end

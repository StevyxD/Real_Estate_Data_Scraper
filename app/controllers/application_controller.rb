class ApplicationController < ActionController::Base
  include Pagy::Backend

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # Default the page to English on first visit: the scraped data is Marathi, so
  # Google Translate (source = mr) renders it in English. The navbar toggle then
  # switches between /mr/en (English) and /mr/mr (native Marathi).
  before_action :default_to_english

  private

  def default_to_english
    cookies[:googtrans] = { value: "/mr/en", path: "/" } unless cookies.key?(:googtrans)
  end
end

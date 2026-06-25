# Retry-scheduling fields so the scraper can recover from the flaky portal
# unattended: a failed property is parked with a +next_retry_at+ (exponential
# backoff) and re-attempted automatically once it comes due, instead of sitting
# in :error forever waiting for a manual `rake igr:scrape_pending`.
class AddRetrySchedulingToProperties < ActiveRecord::Migration[8.1]
  def change
    # How many real (non-outage) attempts a property has burned; it is given up
    # on only after Property::MAX_ATTEMPTS of these.
    add_column :properties, :attempts, :integer, default: 0, null: false
    # When this property becomes eligible to scrape again (NULL = right now).
    add_column :properties, :next_retry_at, :datetime
    # Classification of the last failure: "outage" (site/network down — don't
    # burn an attempt) vs "app" (something specific to this property).
    add_column :properties, :last_error_kind, :string

    # The dispatcher repeatedly asks "what's due, oldest first?" — index it.
    add_index :properties, :next_retry_at
  end
end

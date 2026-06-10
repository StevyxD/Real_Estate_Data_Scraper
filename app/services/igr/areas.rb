require "yaml"

module Igr
  # Mumbai District -> Area/Locality mapping, sourced from
  # config/igr_areas.yml (generated from Mumbai_Areas_District_List.xlsx).
  # District names are normalised to match Igr::MumbaiSession::DISTRICT_VALUES
  # ("Mumbai City" / "Mumbai Suburban"), so a selection here feeds the scraper.
  module Areas
    MAP = YAML.load_file(Rails.root.join("config/igr_areas.yml")).freeze

    module_function

    def map = MAP

    def districts = MAP.keys

    def areas_for(district) = MAP.fetch(district, [])

    def valid?(district, area)
      areas_for(district).include?(area)
    end
  end
end

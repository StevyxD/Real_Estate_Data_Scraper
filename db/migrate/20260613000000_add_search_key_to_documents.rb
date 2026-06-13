class AddSearchKeyToDocuments < ActiveRecord::Migration[8.1]
  def change
    # Phonetic (consonant-skeleton) index of building/party/description text for
    # English-friendly search over the Marathi data. Populated by Igr::SearchKey
    # via a before_save callback; backfilled after migrating.
    add_column :documents, :search_key, :text
  end
end

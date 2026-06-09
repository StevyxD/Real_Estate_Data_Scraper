# Indexes backing the documents index page filters/sorts (by type, by
# registration date, by price).
class AddSearchIndexesToDocuments < ActiveRecord::Migration[8.1]
  def change
    add_index :documents, :doc_type
    add_index :documents, :registration_date
    add_index :documents, :consideration_amount
  end
end

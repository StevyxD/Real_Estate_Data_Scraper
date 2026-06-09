# A Document is one registration row scraped from the IGR results grid for a
# Property. The list grid fills the basic columns; the IndexII (सूची क्र.2)
# detail page fills the financial/area/PAN columns in a later migration.
class CreateDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :documents do |t|
      t.references :property, null: false, foreign_key: true
      t.string :doc_number
      t.string :doc_type
      t.date :registration_date
      t.string :sro_name
      t.string :sro_code
      t.text :seller_names
      t.text :purchaser_names
      t.decimal :consideration_amount, precision: 15, scale: 2
      t.decimal :market_value, precision: 15, scale: 2
      t.string :area
      t.string :area_unit
      t.decimal :stamp_duty, precision: 15, scale: 2
      t.decimal :registration_fee, precision: 15, scale: 2
      t.jsonb :raw, default: {}

      t.timestamps
    end

    add_index :documents, :doc_number
  end
end

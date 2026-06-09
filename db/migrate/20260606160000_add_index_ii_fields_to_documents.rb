# Columns filled from the IndexII (सूची क्र.2) detail report, which opens in a
# new window from the results grid and carries the consideration/market value,
# area, floor/tower/building, CTS, PAN numbers, and the full raw report (jsonb).
class AddIndexIiFieldsToDocuments < ActiveRecord::Migration[8.1]
  def change
    change_table :documents, bulk: true do |t|
      t.decimal :area_sqft, precision: 12, scale: 2
      t.string :unit_no
      t.string :floor
      t.string :tower_wing
      t.string :building_name
      t.string :cts_number
      t.string :pincode
      t.text :property_description
      t.date :execution_date
      t.string :seller_pan
      t.string :purchaser_pan
      t.jsonb :index_ii, default: {}
      t.boolean :index_ii_fetched, null: false, default: false
    end

    add_index :documents, :index_ii_fetched
  end
end

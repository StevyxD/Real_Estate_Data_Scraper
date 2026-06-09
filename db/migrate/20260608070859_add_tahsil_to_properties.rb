# Rest-of-Maharashtra expansion: the second search form has a
# District -> Tahsil -> Village cascade, so a property is now keyed by tahsil
# too. Mumbai-tab properties leave tahsil blank ("").
class AddTahsilToProperties < ActiveRecord::Migration[8.1]
  def change
    add_column :properties, :tahsil, :string, null: false, default: ""

    remove_index :properties, name: "index_properties_on_search_key"
    add_index :properties, %i[year district tahsil village property_no],
              unique: true, name: "index_properties_on_search_key"
  end
end

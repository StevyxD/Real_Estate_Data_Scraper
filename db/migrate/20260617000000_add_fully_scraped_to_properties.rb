class AddFullyScrapedToProperties < ActiveRecord::Migration[8.1]
  def change
    # false ⇒ the page-walk was cut short (e.g. the portal stopped serving the
    # next page) and the property should be re-scraped to capture the rest.
    add_column :properties, :fully_scraped, :boolean, default: true, null: false
    add_index :properties, :fully_scraped
  end
end

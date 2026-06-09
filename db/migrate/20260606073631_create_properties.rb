# A Property is one search target on the IGR portal: a (year, district, tahsil,
# village, property_no) tuple. The scraper claims pending rows and records the
# outcome (found / empty / error) plus how many captcha attempts it took.
class CreateProperties < ActiveRecord::Migration[8.1]
  def change
    create_table :properties do |t|
      t.integer :year, null: false
      t.string :district, null: false
      t.string :village, null: false
      t.integer :property_no, null: false
      t.string :search_status, null: false, default: "pending"
      t.datetime :scraped_at
      t.integer :captcha_attempts, null: false, default: 0
      t.text :error_message

      t.timestamps
      t.datetime :enqueued_at
    end

    # Tahsil is added later (Rest-of-Maharashtra expansion); the Mumbai tab
    # leaves it blank, so the original unique key omits it.
    add_index :properties, %i[year district village property_no],
              unique: true, name: "index_properties_on_search_key"
    add_index :properties, :search_status
  end
end

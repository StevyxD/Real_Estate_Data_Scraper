class DocumentsController < ApplicationController
  SORTS = {
    "recent"     => { registration_date: :desc },
    "oldest"     => { registration_date: :asc },
    "price_high" => { consideration_amount: :desc },
    "price_low"  => { consideration_amount: :asc },
    "area"       => { area_sqft: :desc }
  }.freeze

  def index
    @query   = params[:q].to_s.strip
    @village = params[:village].to_s.strip
    @sort    = SORTS.key?(params[:sort]) ? params[:sort] : "recent"

    scope = filtered_scope
    @total_value = scope.sum(:consideration_amount)
    @pagy, @documents = pagy(scope.order(SORTS[@sort]).order(id: :desc).includes(:property))

    @villages = villages_with_documents
  end

  def show
    @document = Document.includes(:property).find(params[:id])
  end

  private

  def filtered_scope
    scope = Document.all
    scope = search(scope, @query) if @query.present?
    scope = scope.where(property: Property.where(village: @village)) if @village.present?
    scope
  end

  def search(scope, query)
    columns = %w[building_name seller_names purchaser_names doc_number property_description]
    clause  = columns.map { |c| "documents.#{c} ILIKE :q" }.join(" OR ")
    scope.where(clause, q: "%#{sanitize_sql_like(query)}%")
  end

  def sanitize_sql_like(string)
    ActiveRecord::Base.sanitize_sql_like(string)
  end

  def villages_with_documents
    Property.where(id: Document.select(:property_id)).distinct.order(:village).pluck(:village)
  end
end

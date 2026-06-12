class DocumentsController < ApplicationController
  SORTS = {
    "recent"     => { registration_date: :desc },
    "oldest"     => { registration_date: :asc },
    "price_high" => { consideration_amount: :desc },
    "price_low"  => { consideration_amount: :asc },
    "area"       => { area_sqft: :desc }
  }.freeze

  def index
    @query    = params[:q].to_s.strip
    @property = Property.find_by(id: params[:property_id]) if params[:property_id].present?
    requested_village = params[:village].to_s.strip
    # If the user switched the village dropdown away from the pinned property,
    # drop the property and browse that village instead.
    @property = nil if @property && requested_village.present? && requested_village != @property.village
    # A chosen property pins its village so the project-number list stays in view.
    @village  = @property&.village || requested_village
    @sort     = SORTS.key?(params[:sort]) ? params[:sort] : "recent"

    scope = filtered_scope
    @total_value = scope.sum(:consideration_amount)
    @pagy, @documents = pagy(scope.order(SORTS[@sort]).order(id: :desc).includes(:property))

    @villages   = villages_with_documents
    # Project (property) numbers in the chosen village that actually have docs,
    # so the user can drill into one specific number.
    @properties = @village.present? ? properties_for_village(@village) : []
  end

  def show
    @document = Document.includes(:property).find(params[:id])
  end

  private

  def filtered_scope
    scope = Document.all
    scope = search(scope, @query) if @query.present?
    if @property
      scope = scope.where(property_id: @property.id)        # one specific project no.
    elsif @village.present?
      scope = scope.where(property: Property.where(village: @village))
    end
    scope
  end

  # Properties (project numbers) in a village that have at least one document,
  # each with a docs_count for the chip label.
  def properties_for_village(village)
    Property.where(village:)
            .where(id: Document.select(:property_id))
            .select("properties.*, (SELECT COUNT(*) FROM documents " \
                    "WHERE documents.property_id = properties.id) AS docs_count")
            .order(:property_no)
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

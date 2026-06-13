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
    @properties = @village.present? ? properties_for_village(@village).to_a : []
    build_number_window
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

  # Show project numbers one group of 10 at a time (1-10, 11-20 … 91-100) so the
  # chip row stays compact even with hundreds of numbers. Groups with no records
  # are skipped, so arrows/dropdown only ever land on a populated group.
  def build_number_window
    groups = @properties.map { |p| decade_start(p.property_no) }.uniq.sort
    @num_from =
      if params[:num_from].present? && groups.include?(params[:num_from].to_i)
        params[:num_from].to_i
      elsif @property
        decade_start(@property.property_no) # default to the selected number's group
      else
        groups.first
      end
    @property_groups   = groups
    @window_properties = @properties.select { |p| p.property_no.between?(@num_from.to_i, @num_from.to_i + 9) }

    idx = groups.index(@num_from)
    @prev_from = (groups[idx - 1] if idx && idx.positive?)
    @next_from = (groups[idx + 1] if idx && idx < groups.size - 1)
  end

  # First number of the 10-group a property number falls in: 98 -> 91, 5 -> 1.
  def decade_start(number)
    ((number - 1) / 10) * 10 + 1
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

  # Matches either the raw Marathi text (for Devanagari queries) OR the phonetic
  # search_key (so English like "heights", "status vihar", "meeta" finds the
  # Marathi records). All English tokens must be present (AND) to keep it precise.
  def search(scope, query)
    columns    = %w[building_name seller_names purchaser_names doc_number property_description]
    raw_clause = columns.map { |c| "documents.#{c} ILIKE :raw" }.join(" OR ")
    binds      = { raw: "%#{sanitize_sql_like(query)}%" }

    tokens = Igr::SearchKey.call(query).split.select { |t| t.length >= 2 }
    if tokens.any?
      # Whole-token match (space-padded) so a short skeleton like "mt" (मीता) does
      # not match inside a longer token like "lmtd" (limited).
      key_clause = tokens.each_index.map { |i| "(' ' || documents.search_key || ' ') ILIKE :k#{i}" }.join(" AND ")
      tokens.each_with_index { |t, i| binds[:"k#{i}"] = "% #{sanitize_sql_like(t)} %" }
      scope.where("(#{raw_clause}) OR (#{key_clause})", binds)
    else
      scope.where(raw_clause, binds)
    end
  end

  def sanitize_sql_like(string)
    ActiveRecord::Base.sanitize_sql_like(string)
  end

  def villages_with_documents
    Property.where(id: Document.select(:property_id)).distinct.order(:village).pluck(:village)
  end
end

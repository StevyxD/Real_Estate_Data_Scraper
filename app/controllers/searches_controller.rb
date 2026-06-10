class SearchesController < ApplicationController
  YEARS = (2010..Date.current.year).to_a.reverse

  def new
    @years  = YEARS
    @search = { year: Date.current.year.to_s, district: Igr::Areas.districts.first, village: "", property_no: "" }
  end

  def create
    @search = search_params.to_h.symbolize_keys
    village = @search[:village].to_s.strip

    unless Igr::Areas.districts.include?(@search[:district]) && village.present? && @search[:property_no].to_i.positive?
      return render_invalid("Pick a district, and enter a village/area and a property number.")
    end

    property = Property.find_or_initialize_by(
      year: @search[:year].to_i, district: @search[:district], tahsil: "",
      village: village, property_no: @search[:property_no].to_i
    )
    property.assign_attributes(search_status: "pending", enqueued_at: Time.current)

    if property.save
      ScrapePropertyJob.perform_later(property.id)
      redirect_to documents_path,
                  notice: "Queued #{property.label} for scraping. Start the worker with `bin/jobs`."
    else
      render_invalid(property.errors.full_messages.to_sentence)
    end
  end

  private

  def search_params
    params.require(:search).permit(:year, :district, :village, :property_no)
  end

  def render_invalid(message)
    @years = YEARS
    flash.now[:alert] = message
    render :new, status: :unprocessable_entity
  end
end

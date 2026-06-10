import { Controller } from "@hotwired/stimulus"

// Repopulates the "area" <select> with the areas that belong to the chosen
// district. The district->areas map is passed in as a JSON value.
//
//   data-controller="dependent-select"
//   data-dependent-select-map-value="<%= map.to_json %>"
//   data-dependent-select-selected-value="<%= current_area %>"
//   <select data-dependent-select-target="district"
//           data-action="change->dependent-select#populate">
//   <select data-dependent-select-target="area">
export default class extends Controller {
  static targets = ["district", "area"]
  static values = { map: Object, selected: String }

  connect() {
    this.populate()
  }

  populate() {
    const areas = this.mapValue[this.districtTarget.value] || []
    const chosen = this.areaTarget.value || this.selectedValue

    this.areaTarget.innerHTML = ""
    this.areaTarget.add(new Option("----- Select Area -----", ""))

    for (const area of areas) {
      const option = new Option(area, area)
      if (area === chosen) option.selected = true
      this.areaTarget.add(option)
    }

    this.areaTarget.disabled = areas.length === 0
  }
}

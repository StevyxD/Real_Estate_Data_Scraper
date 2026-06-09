require "test_helper"

class Igr::ResultParserTest < ActiveSupport::TestCase
  HTML = <<~HTML.freeze
    <table id="RegistrationGrid">
      <tr><th>DocNo</th><th>DName</th><th>RDate</th><th>SROName</th><th>Seller Name</th>
          <th>Purchaser Name</th><th>Property Description</th><th>SROCode</th><th>Status</th><th>IndexII</th></tr>
      <tr><td>9778</td><td>करारनामा</td><td>03/06/2026</td><td>सह दु.नि.पनवेल 3</td><td>Seller A</td>
          <td>Buyer B</td><td>desc</td><td>398</td><td>4</td><td><a href="#">IndexII</a></td></tr>
      <tr><td colspan="10"><table><tr><td>1</td><td>2</td></tr></table></td></tr>
    </table>
  HTML

  test "parses data rows and skips the pager/footer row" do
    rows = Igr::ResultParser.parse(HTML)
    assert_equal 1, rows.size

    row = rows.first
    assert_equal 0, row.row_index
    assert_equal "9778", row.attrs[:doc_number]
    assert_equal "करारनामा", row.attrs[:doc_type]
    assert_equal Date.new(2026, 6, 3), row.attrs[:registration_date]
    assert_equal "Seller A", row.attrs[:seller_names]
    assert_equal "398", row.attrs[:sro_code]
    assert_equal "करारनामा", row.raw["dname"]
  end

  test "returns [] when there is no grid" do
    assert_equal [], Igr::ResultParser.parse("<html><body>no records</body></html>")
  end
end

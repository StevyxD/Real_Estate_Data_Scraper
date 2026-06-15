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

  PAGED_HTML = <<~HTML.freeze
    <table id="RegistrationGrid">
      <tr><th>DocNo</th><th>DName</th><th>RDate</th><th>SROName</th><th>Seller Name</th>
          <th>Purchaser Name</th><th>Property Description</th><th>SROCode</th><th>Status</th><th>IndexII</th></tr>
      <tr><td>9778</td><td>करारनामा</td><td>03/06/2026</td><td>सह दु.नि.पनवेल 3</td><td>Seller A</td>
          <td>Buyer B</td><td>desc</td><td>398</td><td>4</td><td><a href="#">IndexII</a></td></tr>
      <tr><td colspan="10"><table><tr>
        <td><span>1</span></td>
        <td><a href="javascript:__doPostBack('RegistrationGrid','Page$2')">2</a></td>
        <td><a href="javascript:__doPostBack('RegistrationGrid','Page$3')">3</a></td>
      </tr></table></td></tr>
    </table>
  HTML

  test "pager_target extracts the GridView postback target" do
    assert_equal "RegistrationGrid", Igr::ResultParser.pager_target(PAGED_HTML)
  end

  test "pager_target is nil for a single-page grid (no pager links)" do
    assert_nil Igr::ResultParser.pager_target(HTML)
  end

  test "pager_target is nil for non-grid html" do
    assert_nil Igr::ResultParser.pager_target("<html><body>no records</body></html>")
  end

  test "pager_pages lists every linked page number" do
    assert_equal [2, 3], Igr::ResultParser.pager_pages(PAGED_HTML)
  end

  test "pager_pages is [] when there is no pager" do
    assert_equal [], Igr::ResultParser.pager_pages(HTML)
  end

  # On the last page the pager only links to EARLIER pages (and a back "..."), so
  # "any number > current" is false — the has-next-page signal the walker uses.
  LAST_PAGE_PAGER = <<~HTML.freeze
    <table id="RegistrationGrid">
      <tr><th>DocNo</th></tr><tr><td>1</td></tr>
      <tr><td><table><tr>
        <td><a href="javascript:__doPostBack('RegistrationGrid','Page$1')">...</a></td>
        <td><a href="javascript:__doPostBack('RegistrationGrid','Page$20')">20</a></td>
        <td><span>21</span></td>
      </tr></table></td></tr>
    </table>
  HTML

  test "pager_pages on the last page only references earlier pages" do
    pages = Igr::ResultParser.pager_pages(LAST_PAGE_PAGER)
    assert_equal [1, 20], pages
    assert pages.none? { |n| n > 21 }, "last page should expose no forward link"
  end
end

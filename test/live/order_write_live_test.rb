# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/order"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/fileman_date_parser"

# Order.check (ORWDXC ACCEPT, rpms-rpc#454) then Order.save unreleased (ORWDX
# SAVE, #455), read back through Order.list and ORDER (#100) via DDR. ORWDX
# SEND (#456) is out of scope. It WRITES against a disposable local container.
class OrderWriteLiveTest < LiveSpec::Test
  writes!

  DFN = 990_034 # synthetic patient; not used by other live order specs
  ORDER_FILE = "100"
  DIALOG = "OR GXTEXT WORD PROCESSING ORDER"
  DISPLAY_GROUP = "13" # NURSING on dialog IEN 49 (#101.41 field 5)
  LOCATION = "7" # CHART REVIEW (Scheduling.hospital_locations on the build)

  P_COMMENT = 15
  P_START = 6
  P_STOP = 24

  ORDER_SNIPPET = "rpms-rpc live spec order write readback"

  def test_check_accept_then_save_leaves_an_unreleased_order_on_file
    start = server_now_fm
    check = RpmsRpc::Order.check(
      DFN,
      filler_id: "OR",
      location: LOCATION,
      items: [ { orderable_item: "8", package: "OR", package_info: "" } ],
      start: start
    )
    unless check.available?
      assert_equal "order checks unavailable: empty reply", check.unavailable_reason,
                   "this build's order checking must answer empty or checks are broken: #{check.inspect}"
    end

    text = "#{ORDER_SNIPPET} #{persona}"
    responses = ordialog_responses(start, text)
    saved = RpmsRpc::Order.save(DFN, client.duz, LOCATION, DIALOG, responses, display_group: DISPLAY_GROUP)

    assert saved[:success], "Order.save answered #{saved.inspect}"
    assert_includes [ RpmsRpc::Order::SAVE_STATUS_UNRELEASED, RpmsRpc::Order::SAVE_STATUS_DELAYED ], saved[:status],
                    "save must leave the order unreleased or delayed (ORWORR GETFLDS CSTS)"
    assert saved[:text].join(" ").include?(ORDER_SNIPPET), saved[:text].inspect

    on_file = order_iens_for(DFN)
    assert_includes on_file, saved[:ien], "file 100 must hold order #{saved[:ien]} for DFN #{DFN}"

    rows = RpmsRpc::Order.list(DFN, filter: :unsigned)
    listed = rows.find { |row| row[:ien] == saved[:ien] }
    refute_nil listed, "ORWORR AGET (unsigned) should list IEN #{saved[:ien]}; rows=#{rows.inspect}"
    assert_equal saved[:order_id], listed[:order_id]

    patient = RpmsRpc::DdrFileman.gets_entry(
      file: ORDER_FILE, iens: "#{saved[:ien]},", fields: ".02", flags: "IE"
    )
    refute_nil patient, "DDR GETS on order #{saved[:ien]}"
    refute patient[:error], patient.inspect
    assert_equal "#{DFN};DPT(", patient[:fields].dig(".02", :internal)

    status = RpmsRpc::DdrFileman.gets_entry(
      file: ORDER_FILE, iens: "#{saved[:ien]},", fields: "5", flags: "IE"
    )
    refute_nil status, "DDR GETS on order #{saved[:ien]} status"
    refute status[:error], status.inspect
    assert_equal saved[:status].to_s, status[:fields].dig("5", :internal)
    if saved[:status] == RpmsRpc::Order::SAVE_STATUS_UNRELEASED
      assert_equal "UNRELEASED", status[:fields].dig("5", :external)
    elsif saved[:status] == RpmsRpc::Order::SAVE_STATUS_DELAYED
      assert_equal "DELAYED", status[:fields].dig("5", :external)
    end

    puts "\n#{persona}: order #{saved[:ien]} (#{saved[:status]}) on DFN #{DFN} reads back through list and file 100"
  end

  private

  def ordialog_responses(start, text)
    {
      [ P_START, 1 ] => start,
      [ P_STOP, 1 ] => "",
      [ P_COMMENT, 1 ] => %(ORDIALOG("WP",#{P_COMMENT},1)),
      [ "WP", P_COMMENT, 1, 1, 0 ] => text
    }
  end

  def server_now_fm
    value = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    RpmsRpc::FilemanDateParser.parse_datetime(value)&.then { |t| RpmsRpc::FilemanDateParser.format_datetime(t) } ||
      flunk("ORWU DT NOW answered #{value.inspect}")
  end

  def order_iens_for(dfn)
    listed = RpmsRpc::DdrFileman.lister(file: ORDER_FILE, fields: "@;.02", flags: "IP")
    flunk "DDR LISTER on ORDER (100) gave no reply" if listed.nil?
    flunk "DDR LISTER on ORDER (100) answered an error" if listed[:error]

    listed[:entries].select { |e| e[:pieces].first == "#{dfn};DPT(" }.map { |e| e[:ien].to_i }
  end
end

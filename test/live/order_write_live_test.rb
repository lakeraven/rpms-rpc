# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/order"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/fileman_date_parser"

# Order.save unreleased (ORWDX SAVE, #455), read back through Order.list and
# ORDER (#100) via DDR. Order.check (ORWDXC ACCEPT, #454) is a separate live
# test. Order.sign_and_release (ORWDX SEND, #456) signs and releases a saved
# order and is read back from file 100. OR GXTEXT WORD PROCESSING ORDER
# WRITES against a disposable local container.
#
# The sign-and-release spec needs the persona's electronic signature code in
# RPMS_ESIG (never logged). Without it the spec skips, tracked by #456, rather
# than pass or fail on a code it was never given.
class OrderWriteLiveTest < LiveSpec::Test
  writes!

  DFN = 990_034 # synthetic patient; not used by other live order specs
  ORDER_FILE = "100"
  DIALOG_NAME = "OR GXTEXT WORD PROCESSING ORDER"

  ORDER_SNIPPET = "rpms-rpc live spec order write readback"

  # First N active #101.43 rows per package suffix (field 2 ends with ;99ORD or ;99PSP).
  ORDERABLE_PROBE_LIMIT = 5
  ORDERABLE_PACKAGE_SUFFIXES = { "OR" => "99ORD", "PS" => "99PSP" }.freeze

  def test_save_leaves_an_unreleased_order_on_file
    dialog = resolve_dialog!
    prompts = resolve_dialog_prompts!(dialog.fetch(:name))
    location = resolve_hospital_location!
    display_group = resolve_display_group!(dialog.fetch(:ien))

    start = server_now_fm
    text = "#{ORDER_SNIPPET} #{persona}"
    responses = ordialog_responses(prompts, start, text)
    saved = RpmsRpc::Order.save(
      DFN, client.duz, location, dialog.fetch(:name), responses, display_group: display_group
    )

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

    puts "\n#{persona}: order #{saved[:ien]} (#{saved[:status]}) on DFN #{DFN} " \
         "(dialog #{dialog.fetch(:ien)}, location #{location}, " \
         "prompts COMMENT/START/STOP=#{prompts.values_at(:comment, :start, :stop).join('/')}) " \
         "reads back through list and file 100"
  end

  def test_sign_and_release_releases_a_saved_order_and_reads_it_back
    esig = ENV["RPMS_ESIG"].to_s
    skip_tracked("#456", "RPMS_ESIG (#{persona}'s signature code) is not set; ORWDX SEND is not live-proven") if esig.empty?

    dialog = resolve_dialog!
    prompts = resolve_dialog_prompts!(dialog.fetch(:name))
    location = resolve_hospital_location!
    display_group = resolve_display_group!(dialog.fetch(:ien))
    responses = ordialog_responses(prompts, server_now_fm, "#{ORDER_SNIPPET} sign #{persona}")

    saved = RpmsRpc::Order.save(
      DFN, client.duz, location, dialog.fetch(:name), responses, display_group: display_group
    )
    assert saved[:success], "Order.save answered #{saved.inspect}"
    order_id = saved.fetch(:order_id)

    results = RpmsRpc::Order.sign_and_release(DFN, client.duz, location, [ order_id ], esig)

    assert_equal [ order_id ], results.map { |r| r[:order_id] }, results.inspect
    assert_equal [ :released ], results.map { |r| r[:status] }, results.inspect

    status = RpmsRpc::DdrFileman.gets_entry(
      file: ORDER_FILE, iens: "#{saved[:ien]},", fields: "5", flags: "IE"
    )
    refute_nil status, "DDR GETS on order #{saved[:ien]} status"
    refute status[:error], status.inspect
    internal = status[:fields].dig("5", :internal).to_s
    refute_includes [ RpmsRpc::Order::SAVE_STATUS_UNRELEASED.to_s, RpmsRpc::Order::SAVE_STATUS_DELAYED.to_s ], internal,
                    "order #{saved[:ien]} is still unreleased after sign_and_release (status #{internal.inspect})"

    unsigned = RpmsRpc::Order.list(DFN, filter: :unsigned)
    assert_nil unsigned.find { |row| row[:ien] == saved[:ien] },
               "order #{saved[:ien]} must leave the unsigned list once signed"

    puts "\n#{persona}: order #{saved[:ien]} signed and released on DFN #{DFN} (status #{internal})"
  end

  def test_order_checks_return_check_rows
    location = resolve_hospital_location!
    start = server_now_fm
    build = LiveSpec.build_label
    tried = []

    ORDERABLE_PACKAGE_SUFFIXES.each do |package, suffix|
      active_orderable_rows(suffix, ORDERABLE_PROBE_LIMIT).each do |row|
        item = order_check_item_for(row, package)
        next if item.nil?

        label = "101.43 IEN #{row[:ien]} package #{package}"
        tried << label

        2.times do
          check = RpmsRpc::Order.check(
            DFN,
            filler_id: "OR",
            location: location,
            items: [ item ],
            start: start
          )
          next unless check.available? && check.checks.any?

          assert_order_check_rows!(check)
          puts "\n#{persona}: ORWDXC ACCEPT returned #{check.checks.size} check row(s) for #{label}"
          return
        end
      end
    end

    detail = tried.empty? ? "no active #101.43 orderables for OR/PS packages" : tried.join(", ")
    skip_tracked(
      "#383",
      "#{detail} returned no ORWDXC check rows on #{build}; order checks are not live-proven"
    )
  end

  private

  def assert_order_check_rows!(check)
    check.checks.each do |row|
      assert row.order_id.is_a?(String), "CheckResult check order_id must be a String: #{row.inspect}"
      assert row.check_ien.is_a?(String), "CheckResult check check_ien must be a String: #{row.inspect}"
      assert row.severity.is_a?(Symbol), "CheckResult check severity must be a Symbol: #{row.inspect}"
      assert row.text.is_a?(String), "CheckResult check text must be a String: #{row.inspect}"
      assert row.extended_text_key.nil? || row.extended_text_key.is_a?(String),
             "CheckResult check extended_text_key must be nil or String: #{row.inspect}"
    end
  end

  # Field 7 = "1" marks inactive on #101.43; field 2 ends with ;99ORD or ;99PSP.
  def active_orderable_rows(suffix, limit)
    listed = RpmsRpc::DdrFileman.lister(file: "101.43", fields: ".01;2;7", flags: "IP", max: 2000)
    flunk "DDR LISTER on ORDERABLE ITEM (#101.43) gave no reply" if listed.nil?
    flunk "DDR LISTER on ORDERABLE ITEM (#101.43) answered an error" if listed[:error]

    rows = []
    listed[:entries].each do |row|
      break if rows.size >= limit

      next if row[:pieces][2].to_s == "1"
      next unless row[:pieces][1].to_s.end_with?(";#{suffix}")

      rows << row
    end
    rows
  end

  def order_check_item_for(row, package)
    ien = row[:ien].to_s
    return nil unless ien.match?(/\A\d+\z/)

    case package
    when "OR"
      { orderable_item: ien, package: "OR", package_info: "" }
    when "PS"
      drug = row[:pieces][1].to_s.split(";").first
      return nil unless drug.match?(/\A\d+\z/)

      { orderable_item: ien, package: "PS", package_info: drug }
    end
  end

  def resolve_dialog!
    listed = RpmsRpc::DdrFileman.lister(file: "101.41", fields: ".01", flags: "IP")
    flunk "DDR LISTER on ORDER DIALOG (#101.41) gave no reply" if listed.nil?
    flunk "DDR LISTER on ORDER DIALOG (#101.41) answered an error" if listed[:error]

    entry = listed[:entries].find { |row| row[:pieces].first == DIALOG_NAME }
    flunk "no ORDER DIALOG (#101.41) entry named #{DIALOG_NAME.inspect} on this build" if entry.nil?

    { name: DIALOG_NAME, ien: entry[:ien].to_s }
  end

  # ORWDX DLGDEF(LST,DLG) answers NAME^promptIEN^sequence (e.g. COMMENT^15^1).
  def resolve_dialog_prompts!(dialog_name)
    lines = Array(client.call_rpc("ORWDX DLGDEF", dialog_name)).flat_map { |chunk| chunk.to_s.split(/\r\n|\r|\n/) }
    flunk "ORWDX DLGDEF returned no rows for dialog #{dialog_name.inspect}" if lines.empty?

    by_name = {}
    lines.each do |line|
      name, rest = line.split("^", 2)
      ien = rest.to_s.split("^").first
      next if name.to_s.empty? || ien.to_s !~ /\A\d+\z/

      by_name[name.to_s.upcase] = ien.to_i
    end

    missing = %w[COMMENT START STOP].reject { |key| by_name.key?(key) }
    flunk "ORWDX DLGDEF for #{dialog_name.inspect} missing prompt(s): #{missing.join(', ')}" unless missing.empty?

    { comment: by_name.fetch("COMMENT"), start: by_name.fetch("START"), stop: by_name.fetch("STOP") }
  end

  # ORDER DIALOG (#101.41) field 5 is DISPLAY GROUP.
  def resolve_display_group!(dialog_ien)
    entry = RpmsRpc::DdrFileman.gets_entry(file: "101.41", iens: "#{dialog_ien},", fields: "5", flags: "IE")
    flunk "DDR GETS on ORDER DIALOG #{dialog_ien} display group gave no reply" if entry.nil?
    flunk "DDR GETS on ORDER DIALOG #{dialog_ien} display group answered an error" if entry[:error]

    internal = entry[:fields].dig("5", :internal).to_s
    flunk "ORDER DIALOG #{dialog_ien} (#101.41) field 5 (DISPLAY GROUP) is blank on this build" if internal.empty?

    internal
  end

  def resolve_hospital_location!
    locations = RpmsRpc::Scheduling.hospital_locations
    flunk "Scheduling.hospital_locations returned no rows on this build" if locations.empty?

    active = locations.find { |row| row[:inactivate_date].nil? }
    flunk "Scheduling.hospital_locations has no active location on this build" if active.nil?

    ien = active.fetch(:location_ien).to_s
    flunk "active hospital location from Scheduling.hospital_locations has a blank IEN" if ien.empty?

    ien
  end

  def ordialog_responses(prompts, start, text)
    comment = prompts.fetch(:comment)
    start_ien = prompts.fetch(:start)
    stop_ien = prompts.fetch(:stop)
    {
      [ start_ien, 1 ] => start,
      [ stop_ien, 1 ] => "",
      [ comment, 1 ] => %(ORDIALOG("WP",#{comment},1)),
      [ "WP", comment, 1, 1, 0 ] => text
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

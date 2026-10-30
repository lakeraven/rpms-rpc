# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/order"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/fileman_date_parser"

# Order.check (ORWDXC ACCEPT, rpms-rpc#454) then Order.save unreleased (ORWDX
# SAVE, #455), read back through Order.list and ORDER (#100) via DDR. ORWDX
# SEND (#456) is out of scope. It WRITES against a disposable local container.
class OrderWriteLiveTest < LiveSpec::Test
  writes!

  DFN = 990_034 # synthetic patient; not used by other live order specs
  ORDER_FILE = "100"
  DIALOG_NAME = "OR GXTEXT WORD PROCESSING ORDER"

  ORDER_SNIPPET = "rpms-rpc live spec order write readback"

  def test_check_accept_then_save_leaves_an_unreleased_order_on_file
    dialog = resolve_dialog!
    prompts = resolve_dialog_prompts!(dialog.fetch(:name))
    location = resolve_hospital_location!
    orderable = resolve_orderable_for_dialog!(dialog.fetch(:ien))
    display_group = resolve_display_group!(dialog.fetch(:ien))

    start = server_now_fm
    check = RpmsRpc::Order.check(
      DFN,
      filler_id: "OR",
      location: location,
      items: [ { orderable_item: orderable, package: "OR", package_info: "" } ],
      start: start
    )
    unless check.available?
      assert_equal "order checks unavailable: empty reply", check.unavailable_reason,
                   "empty ORWDXC ACCEPT reply is the gem fail-closed contract (CheckResult.unavailable), not proof order checks ran"
    end
    if check.available?
      refute_empty check.checks, "ORWDXC ACCEPT returned no check rows: #{check.inspect}"
      check.checks.each do |row|
        assert row.order_id.is_a?(String), "CheckResult check order_id must be a String: #{row.inspect}"
        assert row.check_ien.is_a?(String), "CheckResult check check_ien must be a String: #{row.inspect}"
        assert row.severity.is_a?(Symbol), "CheckResult check severity must be a Symbol: #{row.inspect}"
        assert row.text.is_a?(String), "CheckResult check text must be a String: #{row.inspect}"
        assert row.extended_text_key.nil? || row.extended_text_key.is_a?(String),
               "CheckResult check extended_text_key must be nil or String: #{row.inspect}"
      end
    end

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
         "(dialog #{dialog.fetch(:ien)}, location #{location}, orderable #{orderable}, " \
         "prompts COMMENT/START/STOP=#{prompts.values_at(:comment, :start, :stop).join('/')}) " \
         "reads back through list and file 100"
  end

  private

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
      name, ien, seq = line.split("^", 3)
      next if name.to_s.empty? || ien.to_s !~ /\A\d+\z/

      key = name.to_s.upcase
      by_name[key] = ien.to_i if seq.to_s == "1" || !by_name.key?(key)
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

  # #101.43 field 2 points at the dialog IEN (first ; piece of the ORDER DIALOG pointer).
  def resolve_orderable_for_dialog!(dialog_ien)
    listed = RpmsRpc::DdrFileman.lister(file: "101.43", fields: ".01;2", flags: "IP")
    flunk "DDR LISTER on ORDERABLE ITEM (#101.43) gave no reply" if listed.nil?
    flunk "DDR LISTER on ORDERABLE ITEM (#101.43) answered an error" if listed[:error]

    matches = listed[:entries].select do |row|
      row[:pieces][1].to_s.split(";").first == dialog_ien
    end
    flunk "no ORDERABLE ITEM (#101.43) points at ORDER DIALOG IEN #{dialog_ien} on this build" if matches.empty?

    matches.min_by { |row| row[:ien].to_i }.fetch(:ien).to_s
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

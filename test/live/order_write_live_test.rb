# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/order"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/fileman_date_parser"

# Order.save unreleased (ORWDX SAVE, #455), read back through Order.list and
# ORDER (#100) via DDR. Order.check (ORWDXC ACCEPT, #454) is a separate live
# test: it orders the drug of an active prescription again, for the same
# patient, and must see the duplicate-drug check fire (#847).
# Order.sign_and_release (ORWDX SEND, #456) signs and releases a saved
# order and is read back from file 100. OR GXTEXT WORD PROCESSING ORDER
# WRITES against a disposable local container.
#
# The sign-and-release spec needs the provider's electronic signature code:
# the provider row's, or RPMS_ESIG (never logged, #848). Every provider run
# has it (README, Test roles), so a run
# without it fails and says so, rather than skip and leave signing unproven
# (#851).
class OrderWriteLiveTest < LiveSpec::Test
  runs_as :provider
  writes!

  DFN = 990_034 # synthetic patient; not used by other live order specs
  ORDER_FILE = "100"
  DIALOG_NAME = "OR GXTEXT WORD PROCESSING ORDER"

  ORDER_SNIPPET = "rpms-rpc live spec order write readback"

  # PRESCRIPTION (#52) field 100 STATUS: 0 is ACTIVE.
  RX_STATUS_ACTIVE = "0"
  # ORDER CHECKS (#100.8) entry the duplicate-drug check files under.
  DUPLICATE_DRUG_CHECK = "DUPLICATE DRUG ORDER"

  def test_save_leaves_an_unreleased_order_on_file
    dialog = resolve_dialog!
    prompts = resolve_dialog_prompts!(dialog.fetch(:name))
    location = resolve_hospital_location!
    display_group = resolve_display_group!(dialog.fetch(:ien))

    start = server_now_fm
    text = "#{ORDER_SNIPPET} #{role}"
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

    puts "\n#{role}: order #{saved[:ien]} (#{saved[:status]}) on DFN #{DFN} " \
         "(dialog #{dialog.fetch(:ien)}, location #{location}, " \
         "prompts COMMENT/START/STOP=#{prompts.values_at(:comment, :start, :stop).join('/')}) " \
         "reads back through list and file 100"
  end

  def test_sign_and_release_releases_a_saved_order_and_reads_it_back
    esig = signature_code!

    dialog = resolve_dialog!
    prompts = resolve_dialog_prompts!(dialog.fetch(:name))
    location = resolve_hospital_location!
    display_group = resolve_display_group!(dialog.fetch(:ien))
    responses = ordialog_responses(prompts, server_now_fm, "#{ORDER_SNIPPET} sign #{role}")

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

    puts "\n#{role}: order #{saved[:ien]} signed and released on DFN #{DFN} (status #{internal})"
  end

  # USID^ORWDXC reads an outpatient drug item's PkgInfo as a DRUG (#50) IEN
  # (ORDRUG=+$P(ORITMX,U,3)), not the #50.7 IEN in the orderable's ID, so the
  # spec sends the prescription's own drug. An empty ACCEPT reply means the
  # checks are unknown, never that there is nothing to report: it fails here.
  def test_order_checks_flag_a_duplicate_of_an_active_prescription
    location = resolve_hospital_location!
    rx = active_prescription!
    orderable = drug_orderable!(rx.fetch(:drug))
    duplicate_ien = order_check_ien!(DUPLICATE_DRUG_CHECK)

    check = RpmsRpc::Order.check(
      rx.fetch(:dfn),
      filler_id: "PS",
      location: location,
      items: [ { orderable_item: orderable.fetch(:ien), package: "PS", package_info: rx.fetch(:drug) } ],
      start: server_now_fm
    )

    assert check.available?,
           "ORWDXC ACCEPT for #{orderable.fetch(:name)} on DFN #{rx.fetch(:dfn)} is not a usable answer " \
           "(#{check.inspect}); an empty or failed reply is unknown, not \"no problems\""
    assert_order_check_rows!(check)
    duplicate = check.checks.find { |row| row.check_ien == duplicate_ien }
    refute_nil duplicate,
               "no #{DUPLICATE_DRUG_CHECK} (#100.8 IEN #{duplicate_ien}) row for #{orderable.fetch(:name)} on " \
               "DFN #{rx.fetch(:dfn)}, which holds active prescription #{rx.fetch(:number)}; rows=#{check.checks.inspect}"
    assert_match(/duplicate drug order/i, duplicate.text)
    assert_includes duplicate.text, orderable.fetch(:name), duplicate.text

    puts "\n#{role}: ORWDXC ACCEPT flagged #{orderable.fetch(:name)} (drug #{rx.fetch(:drug)}) as a duplicate " \
         "of prescription #{rx.fetch(:number)} on DFN #{rx.fetch(:dfn)}: #{duplicate.text}"
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

  # The first ACTIVE PRESCRIPTION (#52): its patient (field 2), DRUG (#50,
  # field 6) and RX # (.01).
  def active_prescription!
    listed = RpmsRpc::DdrFileman.lister(file: "52", fields: ".01;2;6;100", flags: "IP", max: 500)
    flunk "DDR LISTER on PRESCRIPTION (#52) gave no reply" if listed.nil?
    flunk "DDR LISTER on PRESCRIPTION (#52) answered an error" if listed[:error]

    row = listed[:entries].find do |entry|
      number, dfn, drug, status = entry[:pieces]
      status.to_s == RX_STATUS_ACTIVE && dfn.to_s.match?(/\A\d+\z/) && drug.to_s.match?(/\A\d+\z/) && !number.to_s.empty?
    end
    flunk "no ACTIVE prescription (#52 field 100 = 0) with a patient and a drug on this build: " \
          "the duplicate-drug order check has nothing to duplicate" if row.nil?

    number, dfn, drug, = row[:pieces]
    { number: number.to_s, dfn: dfn.to_i, drug: drug.to_s }
  end

  # The active ORDERABLE ITEM (#101.43) for a DRUG (#50): the drug's
  # PHARMACY ORDERABLE ITEM (#50.7, field 2.1) is the orderable's ID
  # (field 2) "<#50.7 IEN>;99PSP".
  def drug_orderable!(drug)
    entry = RpmsRpc::DdrFileman.gets_entry(file: "50", iens: "#{drug},", fields: "2.1", flags: "IE")
    flunk "DDR GETS on DRUG (#50) #{drug} gave no reply" if entry.nil?
    flunk "DDR GETS on DRUG (#50) #{drug} answered an error" if entry[:error]

    pharmacy_item = entry[:fields].dig("2.1", :internal).to_s
    flunk "DRUG (#50) #{drug} has no PHARMACY ORDERABLE ITEM (field 2.1)" unless pharmacy_item.match?(/\A\d+\z/)

    listed = RpmsRpc::DdrFileman.lister(file: "101.43", fields: ".01;2;7", flags: "IP", max: 5000)
    flunk "DDR LISTER on ORDERABLE ITEM (#101.43) gave no reply" if listed.nil?
    flunk "DDR LISTER on ORDERABLE ITEM (#101.43) answered an error" if listed[:error]

    row = listed[:entries].find { |e| e[:pieces][1].to_s == "#{pharmacy_item};99PSP" && e[:pieces][2].to_s != "1" }
    flunk "no active ORDERABLE ITEM (#101.43) with ID #{pharmacy_item};99PSP for DRUG (#50) #{drug}" if row.nil?

    { ien: row[:ien].to_s, name: row[:pieces][0].to_s.strip }
  end

  def order_check_ien!(name)
    listed = RpmsRpc::DdrFileman.lister(file: "100.8", fields: ".01", flags: "IP", max: 500)
    flunk "DDR LISTER on ORDER CHECKS (#100.8) gave no reply" if listed.nil?
    flunk "DDR LISTER on ORDER CHECKS (#100.8) answered an error" if listed[:error]

    row = listed[:entries].find { |e| e[:pieces].first.to_s == name }
    flunk "no ORDER CHECKS (#100.8) entry named #{name.inspect} on this build" if row.nil?

    row[:ien].to_s
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

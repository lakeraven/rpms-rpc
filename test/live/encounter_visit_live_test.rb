# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/encounter"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/fileman_date_parser"

# Visit open/create over BEHOENCX on seed patient DFN 2, visit IEN 1 (#563).
class EncounterVisitLiveTest < LiveSpec::Test
  writes!

  DFN = 2
  VISIT_IEN = 1
  LOCATION_IEN = 6
  VISIT_FILE = "9000010"
  PCC_MASTER_CONTROL_FILE = "9001000"

  def test_open_visit_one_lists_no_component_the_server_reports_present
    result = RpmsRpc::Encounter.open(DFN, VISIT_IEN)
    refute_nil result, "visit IEN #{VISIT_IEN} must open for DFN #{DFN}"
    assert_equal VISIT_IEN, result[:visit_ien]
    assert_equal DFN, result[:patient_dfn]
    assert_equal LOCATION_IEN, result[:location_ien]

    assert_equal [ { component: "E&M", message: "Visit has no note" } ], result[:missing_components]
  end

  def test_create_is_get_or_create_and_reads_back
    if persona == "SYS123"
      datetime = unlikely_past_visit_datetime_fm
      vstr_args = {
        location_ien: LOCATION_IEN,
        datetime: datetime,
        service_category: "A",
        create: 1
      }
      date_part = datetime.split(".").first

      before = newest_visit_ien
      first = RpmsRpc::Encounter.create(DFN, **vstr_args)
      assert first[:success], "SYS123 create should succeed: #{first.inspect}"
      visit_ien = first[:visit_ien]
      assert visit_ien.is_a?(Integer) && visit_ien.positive?
      assert visit_ien > before, "CREATE=1 must add a new ^AUPNVSIT entry (was #{before}, got #{visit_ien})"

      second = RpmsRpc::Encounter.create(DFN, **vstr_args)
      assert second[:success]
      assert_equal visit_ien, second[:visit_ien], "identical CREATE=1 must return the same visit IEN"

      found = RpmsRpc::Encounter.create(DFN, **vstr_args.merge(create: 0))
      assert found[:success]
      assert_equal visit_ien, found[:visit_ien]

      row = RpmsRpc::DataMapper.encounter_visit.fetch_one(visit_ien.to_s)
      refute_nil row
      assert_equal DFN, row[:patient_dfn]
      assert_equal LOCATION_IEN, row[:location_ien]
      assert_equal "A", row[:service_category]
      assert row[:datetime_raw].to_s.start_with?(date_part),
             "GETVISIT datetime_raw #{row[:datetime_raw].inspect} must start with sent date #{date_part.inspect}"
    elsif persona == "PROV123"
      # PROV123 pins the named seed gap: division 1 has no #9001000 PCC MASTER CONTROL entry,
      # so ADDVIST returns TYPE OF VISIT MISSING / Error Creating Visit until openrpms seeds it.
      # The cause is read live before the create (#721): both reads must answer with data.
      division = signed_on_division_ien
      master_control = pcc_master_control_iens
      refute_includes master_control, division,
                      "division #{division} now has a ##{PCC_MASTER_CONTROL_FILE} PCC MASTER CONTROL entry " \
                      "(listed: #{master_control.inspect}): the seed gap looks fixed (openrpms#1078). Regrade the " \
                      "BEHOENCX FETCH CREATE=1 readiness row and make this branch prove the create and the " \
                      "GETVISIT read-back as the SYS123 branch does"

      datetime = server_now_fm
      vstr_args = {
        location_ien: LOCATION_IEN,
        datetime: datetime,
        service_category: "A",
        create: 1
      }
      before = newest_visit_ien
      result = RpmsRpc::Encounter.create(DFN, **vstr_args)
      refute result[:success]
      assert_equal "Error Creating Visit", result[:error]
      after = newest_visit_ien
      assert_equal before, after, "refused create must not add a ^AUPNVSIT entry"
    else
      flunk "persona #{persona.inspect} is not pinned — this spec covers SYS123 and PROV123 only (see README)"
    end
  end

  private

  def server_now_fm
    value = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    RpmsRpc::FilemanDateParser.parse_datetime(value)&.then { |t| RpmsRpc::FilemanDateParser.format_datetime(t) } ||
      flunk("ORWU DT NOW did not yield a FileMan datetime")
  end

  def unlikely_past_visit_datetime_fm
    base = server_now_fm
    now = RpmsRpc::FilemanDateParser.parse_datetime(base)
    flunk("server now #{base.inspect} did not parse as FileMan datetime") unless now

    shifted = now - (rand(30..3000) * 86_400) - (rand(0..59) * 60)
    RpmsRpc::FilemanDateParser.format_datetime(shifted)
  end

  # DUZ(2), piece 1 of line 3 of XUS GET USER INFO (USERINFO^XUSRB2). The RPC is
  # refused outside the XUS SIGNON context.
  def signed_on_division_ien
    info = client.with_context("XUS SIGNON") { RpmsRpc::DataMapper.user_info.fetch_lines }
    flunk "XUS GET USER INFO answered nothing for #{persona}, so the signed-on division is unknown" if info.nil?

    division = info[:current_site].to_s.split("^", -1).first.to_s
    unless division.match?(/\A[1-9]\d*\z/)
      flunk "XUS GET USER INFO current_site #{info[:current_site].inspect} does not lead with a division IEN"
    end

    division.to_i
  end

  # Every IEN on file #9001000. A failed, empty or truncated list is no evidence
  # that an entry is absent, so each of those fails.
  def pcc_master_control_iens
    listed = RpmsRpc::DdrFileman.lister(file: PCC_MASTER_CONTROL_FILE, fields: ".01", flags: "IP")
    if listed.nil? || listed[:error] || !listed[:data]
      flunk "DDR LISTER on file #{PCC_MASTER_CONTROL_FILE} failed: #{listed.inspect}"
    end
    flunk "DDR LISTER on file #{PCC_MASTER_CONTROL_FILE} was truncated: #{listed[:more].inspect}" if listed[:more]
    flunk "file #{PCC_MASTER_CONTROL_FILE} lists no entry, so it cannot show which division lacks one" if listed[:entries].empty?

    listed[:entries].map do |entry|
      ien = entry[:ien].to_s
      flunk "file #{PCC_MASTER_CONTROL_FILE} row has a non-numeric IEN: #{entry.inspect}" unless ien.match?(/\A[1-9]\d*\z/)

      ien.to_i
    end
  end

  def newest_visit_ien
    listed = RpmsRpc::DdrFileman.lister(
      file: VISIT_FILE, fields: ".01", flags: "IPB", max: "1", xref: "#"
    )
    flunk "DDR LISTER on file #{VISIT_FILE} failed: #{listed.inspect}" if listed.nil? || listed[:error]
    flunk "no visits on file #{VISIT_FILE}" if listed[:entries].empty?

    listed[:entries].first[:ien].to_i
  end
end

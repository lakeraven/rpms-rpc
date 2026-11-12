# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient_application"
require "rpms_rpc/api/ddr_fileman"

# PATIENT APPLICATIONS (#9000045), filed through DDR FILER inside AG's edit
# lock and read back through FileMan (rpms-ux S-REG-03.3 to 03.5,
# openrpms#1053). Needs PATIENT APPLICATION TYPES (#9000048) to hold a type
# (openrpms SEEDAPPT). An application cannot be deleted through AG, so run on
# a disposable container; each run records one application on a new date.
class PatientApplicationLiveTest < LiveSpec::Test
  writes!

  DFN = 990_010 # a synthetic seed patient
  PA = RpmsRpc::PatientApplication

  def fields(file, iens, list)
    reply = RpmsRpc::DdrFileman.gets_entry(file: file, iens: iens, fields: list, flags: "I")
    refute_nil reply, "DDR GETS ENTRY DATA gave no reply"
    refute reply[:error], "no #{file} entry #{iens}"
    reply[:fields].transform_values { |v| v[:internal] }
  end

  def header
    reply = RpmsRpc::DdrFileman.lister(file: "9000045", fields: "@;.01I", flags: "IP", xref: "B",
                                       from: (DFN - 1).to_s, max: 5)
    reply[:entries].find { |e| e[:pieces][0] == DFN.to_s }&.dig(:ien)
  end

  # A date obtained no application of this patient's already has, in the past year.
  def free_date
    taken = PA.for_patient(DFN).map { |a| a[:obtained] }
    (1..365).map { |n| Date.today - n }.find { |d| !taken.include?(d) }
  end

  def test_s_reg_03_3_to_03_5_an_application_is_recorded_its_outcome_dated_and_it_is_never_deleted
    type = PA.types.find { |t| t[:name] == "MEDICAID FORM 100" }
    refute_nil type, "PATIENT APPLICATION TYPES has no MEDICAID FORM 100 (run openrpms SEEDAPPT)"
    obtained = free_date
    submitted = obtained + 1 > Date.today ? obtained : obtained + 1
    duz = client.duz.to_i

    added = PA.add(DFN, obtained: obtained, type: type[:ien], submitted: submitted, via: "O",
                        reason: "LIVE SPEC", received_by: duz, submitted_by: duz)
    assert added[:success], added.inspect
    app = "#{added[:application]},#{header},"
    assert_equal({ ".01" => RpmsRpc::FilemanDateParser.to_fileman(obtained), ".02" => type[:ien].to_s, ".03" => duz.to_s, ".04" => "P" },
                 fields("9000045.11", app, ".01;.02;.03;.04"))
    sub = "#{added[:submission]},#{app}"
    assert_equal({ ".01" => RpmsRpc::FilemanDateParser.to_fileman(submitted), ".02" => "O", ".03" => "LIVE SPEC", ".04" => duz.to_s },
                 fields("9000045.1101", sub, ".01;.02;.03;.04"))
    today = RpmsRpc::FilemanDateParser.to_fileman(Date.today)
    assert_equal({ ".03" => today, ".12" => duz.to_s, ".16" => today }, fields("9000001", "#{DFN},", ".03;.12;.16"),
                 "UPDATE1^AGED's stamp")

    assert_equal :exists, PA.add(DFN, obtained: obtained, type: type[:ien])[:error]

    assert_equal({ success: true, dated: true },
                 PA.update_status(DFN, application: added[:application], status: "A", date: Date.today))
    assert_equal "A", fields("9000045.11", app, ".04")[".04"]
    status = PA.for_patient(DFN).find { |a| a[:ien] == added[:application] }[:submissions].first[:statuses].last
    assert_equal({ date: Date.today, status: "A" }, status.slice(:date, :status))
    assert_equal({ ".01" => today, ".02" => "A" }, fields("9000045.110101", "#{status[:ien]},#{sub}", ".01;.02"))

    assert PA.update_status(DFN, application: added[:application], status: "E")[:success]
    assert_equal "E", fields("9000045.11", app, ".04")[".04"]
    assert(PA.for_patient(DFN).any? { |a| a[:ien] == added[:application] }, "an application in error stays on file")
  end

  def test_s_reg_03_3_a_future_date_is_refused_and_files_nothing
    before = PA.for_patient(DFN).size

    assert_equal :invalid, PA.add(DFN, obtained: Date.today + 1, type: 1)[:error]
    assert_equal before, PA.for_patient(DFN).size
  end
end

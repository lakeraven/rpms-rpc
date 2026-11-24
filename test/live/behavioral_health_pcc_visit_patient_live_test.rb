# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/fileman_date_parser"

# RpmsRpc::BehavioralHealth.save_pcc_visit never links a BH visit to another
# patient's PCC visit (openrpms#1284).
#
# The FOIA AMHG CREATE/EDIT VISIT does not refuse it. With the division's BH
# PCC link on, PCC^AMHGPCC hands the caller's visit to EN^AMHBHRU, and ADD1
# of AMHPCCL stores it as #9002011 .16 and files the BH visit's V POV and V
# PROVIDER on it, with no check of the visit's patient (AMHPCCL.m:21,33). So
# the gem refuses first: it reads #9002011 .08 and #9000010 .05 before the
# write and refuses when they differ. Since bcer-9.0-20261124-60d39b6-ydb the
# build refuses too (openrpms#1284): the raw RPC answers "0~PCC VISIT IS FOR
# A DIFFERENT PATIENT!", so the second test reads that refusal where it used
# to link the record as setup.
#
# The target is a demo image whose BH PCC link is on and that carries the BH
# records of the panel patient QUEBEC,SAGE (openrpms SEEDBH, openrpms#1267,
# #1272). Two complete BH visits are filed for her, the way the BH GUI files
# them: the visit (save_visit), its POV and activity (AMHG SAVE POV, AMHG SAVE
# ACTIVITY, the GUI's own wire), then the visit again.
#   1. The first, linked to one of her own PCC visits, links: the target really
#      links, so the refusal below is the gem's and not the server's.
#   2. The second, named with a PCC visit of ROMEO,FINLEY, is refused before
#      AMHG CREATE/EDIT VISIT is sent: .16 stays blank, and no V POV of hers
#      lands on his visit.
# A BH visit another client has already linked to his PCC visit (sent here as
# the raw RPC) is refused on its next save too. Stock re-saves a linked record
# through the edit path, 2^AMHPCCL, which deletes every V POV, V PROVIDER, V
# MEASUREMENT and the other V files on the linked visit before it files the BH
# visit's own (AMHPCCL.m:66-73): his own rows would go.
# Remove the patient check from pcc_confirm_target! and both tests go red: the
# server links the record to his visit and files her V POV on it, and the
# re-save deletes his V POVs.
class BehavioralHealthPccVisitPatientLiveTest < LiveSpec::Test
  runs_as :bh_provider
  # Behavioral health work is the BH provider's (PROFILE,BH); releases before bcer-9.0-20261124-60d39b6-ydb lack it.
  needs "AMHGRPC", tracked: "openrpms#1299"
  writes!

  PATIENT = 990_017 # QUEBEC,SAGE, the panel patient SEEDBH files BH records for
  OTHER_PATIENT = 990_018 # ROMEO,FINLEY

  BH_VISIT_FILE = "9002011"
  PCC_VISIT_FILE = "9000010"
  V_POV_FILE = "9000010.07"
  BH_PROBLEM_FILE = "9002012.2"
  PROGRAM = "MENTAL HEALTH"
  APPOINTMENT_WITH = "WALK-IN"
  PROBLEM_CODE = "F32.9"
  PROBLEM_NARRATIVE = "MAJOR DEPRESSIVE DISORDER SINGLE EPISODE"
  ACTIVITY_MINUTES = "30"

  def test_a_pcc_visit_of_another_patient_is_refused_before_anything_is_linked
    assert_synthetic_patient!(PATIENT)
    assert_synthetic_patient!(OTHER_PATIENT)
    own = pcc_visit_of!(PATIENT)
    other = pcc_visit_of!(OTHER_PATIENT)
    reference = seeded_visit_reference!
    problem = problem_ien!

    first = complete_bh_visit!(reference, problem)
    linked = RpmsRpc::BehavioralHealth.save_pcc_visit(record_ien: first, visit_ien: own)
    assert_equal own, linked[:visit_ien], "BH visit #{first} must link to QUEBEC,SAGE's PCC visit #{own}"
    assert_equal own, pcc_link(first)

    second = complete_bh_visit!(reference, problem)
    povs_before = v_povs_of(PATIENT, on: other)
    err = assert_raises(RpmsRpc::BehavioralHealth::SaveError) do
      RpmsRpc::BehavioralHealth.save_pcc_visit(record_ien: second, visit_ien: other)
    end
    assert_match(/PCC visit patient does not match the behavioral health record/, err.message)
    assert_empty pcc_link(second).to_s, "BH visit #{second} must not be linked to ROMEO,FINLEY's PCC visit #{other}"
    assert_equal povs_before, v_povs_of(PATIENT, on: other), "no V POV of QUEBEC,SAGE may be filed on PCC visit #{other}"

    puts "\n#{role}: BH visit #{first} linked to her PCC visit #{own}; BH visit #{second} refused for " \
         "another patient's PCC visit #{other} (.16 blank, no V POV filed)"
  end

  def test_a_bh_visit_already_linked_to_another_patients_pcc_visit_is_refused_before_his_v_files_are_touched
    assert_synthetic_patient!(PATIENT)
    assert_synthetic_patient!(OTHER_PATIENT)
    his = pcc_visits_of(OTHER_PATIENT).reverse.find { |visit| v_povs_of(OTHER_PATIENT, on: visit).any? }
    flunk "ROMEO,FINLEY has no PCC visit with a V POV of his own on this target" unless his
    record = complete_bh_visit!(seeded_visit_reference!, problem_ien!)
    his_povs = v_povs_of(OTHER_PATIENT, on: his)
    reply = client.with_context(RpmsRpc::BehavioralHealth::CONTEXT) do
      client.call_rpc_global_array("AMHG CREATE/EDIT VISIT", "#{record}|#{his}")
    end.to_s
    if reply.include?("PCC VISIT IS FOR A DIFFERENT PATIENT!")
      # openrpms#1284: the build refuses the raw link, so nothing links and his V files stay.
      assert_empty pcc_link(record).to_s, "the build refused, and BH visit #{record} is not linked"
      assert_equal his_povs, v_povs_of(OTHER_PATIENT, on: his), "ROMEO,FINLEY's own V POVs on PCC visit #{his} must stay"
      return puts("\n#{role}: the build refuses linking BH visit #{record} to another patient's PCC visit #{his}")
    end
    refute_match(/0~|M ERROR/, reply, "AMHG CREATE/EDIT VISIT refused the setup: #{reply.inspect}")
    assert_equal his, pcc_link(record), "setup: the FOIA AMHG CREATE/EDIT VISIT links BH visit #{record} to his visit #{his}"

    err = assert_raises(RpmsRpc::BehavioralHealth::SaveError) do
      RpmsRpc::BehavioralHealth.save_pcc_visit(record_ien: record)
    end
    assert_match(/PCC visit patient does not match the behavioral health record/, err.message)
    assert_equal his_povs, v_povs_of(OTHER_PATIENT, on: his), "ROMEO,FINLEY's own V POVs on PCC visit #{his} must stay"

    puts "\n#{role}: BH visit #{record}, linked by the raw RPC to another patient's PCC visit #{his}, " \
         "refused on re-save (his #{his_povs.size} V POV(s) kept)"
  end

  private

  # The newest PCC visit (#9000010) of +dfn+.
  def pcc_visit_of!(dfn)
    pcc_visits_of(dfn).last || flunk("patient #{dfn} has no PCC visit on this target (DDR LISTER #{PCC_VISIT_FILE} AC)")
  end

  # The PCC visits of +dfn+, oldest first, each with its .05 read back as +dfn+.
  def pcc_visits_of(dfn)
    listed = RpmsRpc::DdrFileman.lister(file: PCC_VISIT_FILE, fields: ".01;.05", flags: "IP", xref: "AC", part: dfn.to_s)
    return [] if listed.nil? || listed[:error]

    listed[:entries].select { |r| r[:pieces][1] == dfn.to_s }.map { |r| r[:ien] }
  end

  # Location, community, type of contact, clinic and activity type of a BH
  # visit SEEDBH filed for the panel patient: the values the BH GUI files.
  def seeded_visit_reference!
    listed = RpmsRpc::DdrFileman.lister(file: BH_VISIT_FILE, fields: ".04;.05;.06;.07;.25", flags: "IP", xref: "C",
                                        part: PATIENT.to_s)
    row = listed && !listed[:error] && listed[:entries].find { |r| r[:pieces].first(5).all? { |p| p.to_s.match?(/\A[1-9]\d*\z/) } }
    flunk "QUEBEC,SAGE has no complete BH visit on this target: it is not a demo image with SEEDBH (openrpms#1267)" unless row

    %i[location community activity type_of_contact clinic].zip(row[:pieces]).to_h
  end

  def problem_ien!
    listed = RpmsRpc::DdrFileman.lister(file: BH_PROBLEM_FILE, fields: ".01", flags: "IP", xref: "B", part: PROBLEM_CODE)
    row = listed && !listed[:error] && listed[:entries].find { |r| r[:pieces][0] == PROBLEM_CODE }
    flunk "no BH problem code #{PROBLEM_CODE} on file #{BH_PROBLEM_FILE}" unless row
    row[:ien]
  end

  # One BH visit for the panel patient, complete as EN^AMHBHRU's CHECKREC
  # wants it, filed the way the BH GUI files it.
  def complete_bh_visit!(ref, problem)
    record = save_visit(ref)
    amhg!("AMHG SAVE POV", "E|#{record}|#{problem}~#{PROBLEM_CODE}~#{PROBLEM_NARRATIVE}||||#{PATIENT}|")
    amhg!("AMHG SAVE ACTIVITY", "E|#{record}|#{ref[:activity]}||#{ACTIVITY_MINUTES}|||1|||#{PATIENT}")
    save_visit(ref, record_ien: record)
    filed = gets(BH_VISIT_FILE, record, ".06;.12;.16")
    assert_equal ref[:activity], filed[".06"], "BH visit #{record} has no activity type after AMHG SAVE ACTIVITY"
    refute_empty filed[".12"].to_s, "BH visit #{record} has no activity time after AMHG SAVE ACTIVITY"
    assert_empty filed[".16"].to_s, "a new BH visit #{record} is already linked"
    record
  end

  def save_visit(ref, record_ien: nil)
    RpmsRpc::BehavioralHealth.save_visit(
      record_ien: record_ien, provider: client.duz.to_s, program: PROGRAM, clinic: ref[:clinic],
      type_of_contact: ref[:type_of_contact], encounter_date: @encounter ||= server_now_fm,
      encounter_location: ref[:location], community_of_service: ref[:community],
      appointment_with: APPOINTMENT_WITH, patient: PATIENT, **(record_ien ? { group_name: "" } : {})
    ).to_s
  end

  # The BH GUI's wire for an AMHG save the gem has no method for, under AMHGRPC.
  def amhg!(rpc, wire)
    reply = client.with_context(RpmsRpc::BehavioralHealth::CONTEXT) { client.call_rpc_global_array(rpc, wire) }.to_s
    refute_match(/0~|M ERROR/, reply, "#{rpc} refused the setup: #{reply.inspect}")
  end

  def pcc_link(record) = gets(BH_VISIT_FILE, record, ".16")[".16"]

  # The V POVs (#9000010.07) on PCC visit +on+ whose patient (.02) is +dfn+.
  def v_povs_of(dfn, on:)
    listed = RpmsRpc::DdrFileman.lister(file: V_POV_FILE, fields: ".02;.03", flags: "IP", xref: "AD", part: on.to_s)
    flunk "DDR LISTER #{V_POV_FILE} AD #{on} answered an error" if listed.nil? || listed[:error]
    listed[:entries].select { |r| r[:pieces][0] == dfn.to_s }.map { |r| r[:ien] }.sort
  end

  def gets(file, ien, fields)
    got = RpmsRpc::DdrFileman.gets_entry(file: file, iens: "#{ien},", fields: fields, flags: "I")
    flunk "DDR GETS #{file} #{ien} answered no record" if got.nil? || got[:error] || got[:fields].empty?
    got[:fields].transform_values { |v| v[:internal].to_s.split(";").first.to_s }
  end

  def assert_synthetic_patient!(dfn)
    refute_nil RpmsRpc::Patient.find(dfn), "DFN #{dfn} must exist on this disposable container's demo data"
  end

  def server_now_fm
    value = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    RpmsRpc::FilemanDateParser.parse_datetime(value)&.then { |t| RpmsRpc::FilemanDateParser.format_datetime(t) } ||
      flunk("ORWU DT NOW did not yield a FileMan datetime")
  end
end

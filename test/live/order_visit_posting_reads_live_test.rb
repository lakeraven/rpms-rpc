# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/encounter"
require "rpms_rpc/api/order"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/patient_education"

# Order.delayed_events (OREVNTX PAT), Order.summaries (ORWORR GET4LST),
# Order.clinical_indications (ORWDXIHS CLININD),
# PatientEducation.problem_linked (BGOVPED2 GETPVED),
# Encounter.activity_time (BGOVTM GET) and Patient.postings (BEHOCACV LIST).
# Each answer is checked against the file it reads with DDR: PATIENT EVENT
# (#100.2), ORDER (#100), PROBLEM (#9000011), V PATIENT ED (#9000010.16),
# V ACTIVITY TIME (#9000010.19), TIU DOCUMENT (#8925) and PRF ASSIGNMENT
# (#26.13). Read only.
class OrderVisitPostingReadsLiveTest < LiveSpec::Test
  DFN = 4 # the demo patient with an order, coded problems, a visit's activity time and a clinical warning on the pinned build
  ACTIVITY_VISIT = 4
  EDUCATION_VISIT = 2 # its V PATIENT ED entry names a problem
  FLAGGED_DFN = 990_003 # the synthetic patient with an active record flag

  def test_delayed_events_against_patient_event
    own = listed("100.2", ".01").select { |row| row[:pieces][0].to_s == DFN.to_s }
    delayed = RpmsRpc::Order.delayed_events(DFN)
    if own.empty?
      assert_empty delayed, "DFN #{DFN} has no PATIENT EVENT entry, so OREVNTX PAT lists none"
    else
      assert_empty delayed.map { |e| e[:event_ien] } - own.map { |r| r[:ien].to_i }, "each listed event is the patient's"
    end
  end

  def test_order_details_read_back_against_order
    orders = listed("100", ".02;5;23")
    refute_empty orders, "#100 has no order: is this the pinned image?"
    details = RpmsRpc::Order.summaries(orders.first(3).map { |row| row[:ien] })
    assert_equal orders.first(3).size, details.size
    orders.first(3).zip(details).each do |row, detail|
      assert_equal row[:ien].to_i, detail[:order_id].to_i, detail.inspect
      assert_equal row[:pieces][2].to_i, detail[:display_group_ien], "display group is #100 field 23"
      assert_equal row[:pieces][1].to_i, detail[:status_ien], "status is #100 field 5"
      refute_empty detail[:text], "order #{row[:ien]} has text"
    end
    missing = RpmsRpc::Order.summaries([ 999_999_999 ]).first
    assert_nil missing[:ordered_at], "an order not on file answers a header with only its id"
  end

  def test_clinical_indications_are_the_patients_coded_problems
    coded = listed("9000011", ".02;.12;80001").select do |row|
      row[:pieces][0].to_s == DFN.to_s && !%w[I D].include?(row[:pieces][1]) && !row[:pieces][2].to_s.empty?
    end
    refute_empty coded, "DFN #{DFN} has no coded problem: is this the pinned image?"
    indications = RpmsRpc::Order.clinical_indications(DFN)
    assert_equal coded.map { |r| r[:ien].to_i }.sort, indications.map { |i| i[:problem_ien] }.sort,
                 "the indications are the patient's active coded problems"
    indications.each do |indication|
      row = coded.find { |r| r[:ien].to_i == indication[:problem_ien] }
      assert_equal row[:pieces][2], indication[:snomed], "the concept is PROBLEM 80001"
      assert_equal :problem_list, indication[:source]
    end

    on_visit = RpmsRpc::Order.clinical_indications(DFN, visit_ien: ACTIVITY_VISIT)
    assert_equal indications.map { |i| i[:problem_ien] }.sort, on_visit.map { |i| i[:problem_ien] }.sort
    sources = on_visit.map { |i| i[:source] }
    assert_includes sources, :visit_diagnosis, "visit #{ACTIVITY_VISIT} has a purpose of visit linked to a problem on the pinned build"
    assert_equal sources.sort_by { |s| s == :visit_diagnosis ? 0 : 1 }, sources, "the visit's diagnoses come first"
  end

  def test_problem_linked_education_against_v_patient_ed
    rows = RpmsRpc::PatientEducation.problem_linked(EDUCATION_VISIT)
    refute_empty rows, "BGOVPED2 GETPVED answered nothing for visit #{EDUCATION_VISIT}: is this the pinned image?"
    rows.each do |row|
      fields = entry("9000010.16", row[:ien], ".01;.03;1103")
      assert_equal EDUCATION_VISIT.to_s, fields.dig(".03", :internal), "V PATIENT ED #{row[:ien]} is on the visit"
      assert_equal row[:problem_ien].to_s, fields.dig("1103", :internal), "the problem is field 1103"
      assert_equal fields.dig(".01", :external), row[:topic]
    end
    assert_empty RpmsRpc::PatientEducation.problem_linked(999_999_999)
  end

  def test_activity_time_against_v_activity_time
    entries = listed("9000010.19", ".01;.03;.04")
    row = entries.find { |r| r[:pieces][1].to_s == ACTIVITY_VISIT.to_s }
    refute_nil row, "no V ACTIVITY TIME on visit #{ACTIVITY_VISIT}: is this the pinned image?"
    provider = entry("9000010.19", row[:ien], "1204").dig("1204", :internal).to_i
    got = RpmsRpc::Encounter.activity_time(ACTIVITY_VISIT, provider)
    assert_equal({ ien: row[:ien].to_i, activity_minutes: row[:pieces][0].to_i, travel_minutes: row[:pieces][2].to_i }, got)

    bare = entries.map { |r| r[:pieces][1].to_i }
    other = (1..20).find { |v| !bare.include?(v) }
    assert_nil RpmsRpc::Encounter.activity_time(other, provider), "visit #{other} has no V ACTIVITY TIME"
  end

  def test_postings_against_tiu_document_and_record_flags
    postings = RpmsRpc::Patient.postings(DFN)
    documents = postings.reject { |p| %i[allergies record_flag].include?(p[:kind]) }
    refute_empty documents, "DFN #{DFN} has no TIU posting: is this the pinned image?"
    documents.each do |posting|
      assert_equal DFN.to_s, entry("8925", posting[:ien], ".02").dig(".02", :internal), "TIU DOCUMENT #{posting[:ien]} is the patient's"
    end

    flags = RpmsRpc::Patient.postings(FLAGGED_DFN).select { |p| p[:kind] == :record_flag }
    refute_empty flags, "DFN #{FLAGGED_DFN} has no record flag posting: is this the pinned image?"
    flags.each do |flag|
      assert_equal FLAGGED_DFN.to_s, entry("26.13", flag[:ien], ".01").dig(".01", :internal), "PRF ASSIGNMENT #{flag[:ien]} is the patient's"
    end
    assert_equal RpmsRpc::Patient.flags(FLAGGED_DFN).map { |f| f[:name] }.sort, flags.map { |f| f[:title] }.sort,
                 "the flag postings are the patient's active flags (ORPRF HASFLG)"
  end

  private

  def listed(file, fields)
    got = RpmsRpc::DdrFileman.lister(file: file, fields: fields, flags: "IP", max: "500")
    flunk "DDR LISTER on #{file} failed: #{got.inspect}" if got.nil? || got[:error]
    got[:entries]
  end

  def entry(file, ien, fields)
    got = RpmsRpc::DdrFileman.gets_entry(file: file, iens: "#{ien},", fields: fields, flags: "IE")
    flunk "DDR GETS on #{file} #{ien} failed: #{got.inspect}" if got.nil? || got[:error] || got[:fields].empty?
    got[:fields]
  end
end

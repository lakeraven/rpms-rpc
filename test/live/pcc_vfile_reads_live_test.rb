# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/exam_component"
require "rpms_rpc/api/health_factor"
require "rpms_rpc/api/patient_education"
require "rpms_rpc/api/pov"

# The PCC reads VueCentric's BGO components list a patient's entries with,
# all in CIAV VUECENTRIC: ExamComponent.for_patient (BGOVEXAM GET),
# HealthFactor.for_patient (BGOVHF GET), PatientEducation.for_patient
# (BGOVPED GET) and Pov.for_visit (BGOVPOV GET).
#
# Each read answers the demo patient's entries on the pinned build, and every
# entry it answers is checked against its V file with DDR: the same patient,
# visit and coded value, so a piece read from the wrong position fails. Read
# only.
class PccVfileReadsLiveTest < LiveSpec::Test
  DFN = 4 # the build's demo patient, who carries exams, health factors and education

  def test_exams_read_back_against_v_exam
    read = RpmsRpc::ExamComponent.for_patient(DFN)
    refute_empty read[:exams], "BGOVEXAM GET answered no exams for DFN #{DFN}: is this the pinned image?"
    read[:exams].each do |exam|
      fields = entry("9000010.13", exam[:ien], ".01;.02;.03;.04")
      assert_equal [ exam[:exam_ien].to_s, DFN.to_s, exam[:visit_ien].to_s ], fields.values_at(".01", ".02", ".03").map { |f| f[:internal] }
      assert_equal exam[:exam], fields.dig(".01", :external)
      assert_equal exam[:result], fields.dig(".04", :external)
      assert_kind_of Date, exam[:visit_date]
    end
    assert_equal({ exams: [], refusals: [] }, RpmsRpc::ExamComponent.for_patient(999_999_999))
  end

  def test_health_factors_read_back_against_v_health_factors
    read = RpmsRpc::HealthFactor.for_patient(DFN)
    refute_empty read, "BGOVHF GET answered no health factors for DFN #{DFN}"
    read.each do |factor|
      fields = entry("9000010.23", factor[:ien], ".01;.02;.03")
      assert_equal [ factor[:factor_ien].to_s, DFN.to_s, factor[:visit_ien].to_s ], fields.values_at(".01", ".02", ".03").map { |f| f[:internal] }
      assert_equal factor[:factor], fields.dig(".01", :external)
    end
  end

  def test_patient_education_reads_back_against_v_patient_ed
    read = RpmsRpc::PatientEducation.for_patient(DFN)
    refute_empty read, "BGOVPED GET answered no education for DFN #{DFN}"
    read.each do |ed|
      fields = entry("9000010.16", ed[:ien], ".01;.02;.03;.05")
      assert_equal [ ed[:topic_ien].to_s, DFN.to_s, ed[:visit_ien].to_s, ed[:provider_ien].to_s ],
                   fields.values_at(".01", ".02", ".03", ".05").map { |f| f[:internal] }
    end
    visit = read.first[:visit_ien]
    by_visit = RpmsRpc::PatientEducation.for_patient(DFN, visit_ien: visit)
    assert_equal read.select { |ed| ed[:visit_ien] == visit }.map { |ed| ed[:ien] }, by_visit.map { |ed| ed[:ien] },
                 "the visit filter keeps that visit's entries only"
  end

  def test_a_visits_diagnoses_read_back_against_v_pov
    visit = RpmsRpc::Pov.for_patient(DFN).first&.dig(:visit_ien) || first_pov_visit
    read = RpmsRpc::Pov.for_visit(visit)
    refute_empty read, "BGOVPOV GET answered no diagnoses for visit #{visit}"
    read.each do |pov|
      fields = entry("9000010.07", pov[:ien], ".01;.03;.04")
      assert_equal [ pov[:icd_ien].to_s, visit.to_s ], fields.values_at(".01", ".03").map { |f| f[:internal] }
      assert_equal pov[:icd_code], fields.dig(".01", :external)
      assert_equal pov[:narrative], fields.dig(".04", :external)
      assert_equal visit.to_i, pov[:visit_ien]
    end
    assert_empty RpmsRpc::Pov.for_visit(999_999_999)
  end

  private

  def entry(file, ien, fields)
    got = RpmsRpc::DdrFileman.gets_entry(file: file, iens: "#{ien},", fields: fields, flags: "IE")
    flunk "DDR GETS on #{file} #{ien} failed: #{got.inspect}" if got.nil? || got[:error] || got[:fields].empty?
    got[:fields]
  end

  # The visit of the first V POV on file, when the patient's own list is empty.
  def first_pov_visit
    listed = RpmsRpc::DdrFileman.lister(file: "9000010.07", fields: ".03", flags: "IP", max: "1")
    flunk "DDR LISTER on V POV failed: #{listed.inspect}" if listed.nil? || listed[:error] || listed[:entries].empty?
    listed[:entries].first[:pieces].first.to_i
  end
end

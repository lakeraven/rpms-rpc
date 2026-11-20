# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/clinical_review"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/encounter"
require "rpms_rpc/fileman_date_parser"

# ClinicalReview.record and .for_visit over BGOVUPD SET and BGOVUPD GET, the
# RPCs VueCentric files "allergies reviewed" with (rpms-ux S-TRI-04.1), both
# in CIAV VUECENTRIC. The spec opens an ambulatory visit, files ALLERGY LIST
# REVIEWED on it, reads it back through BGOVUPD GET and through V
# UPDATED/REVIEWED (#9000010.54) with DDR, and checks that a visit of another
# patient is refused with nothing filed and no visit created.
#
# WRITES against a disposable local container only.
class ClinicalReviewLiveTest < LiveSpec::Test
  runs_as :provider
  writes!

  DFN = 2
  OTHER_DFN = 3
  LOCATION_IEN = 6
  REVIEW_FILE = "9000010.54"
  VISIT_FILE = "9000010"

  def test_record_files_allergy_list_reviewed_on_the_visit_and_reads_back
    visit = open_visit!

    result = RpmsRpc::ClinicalReview.record(DFN, visit)
    assert result[:success], "ClinicalReview.record answered #{result.inspect}"
    ien = result[:ien]

    listed = RpmsRpc::ClinicalReview.for_visit(DFN, visit)
    entry = listed.find { |row| row[:ien] == ien }
    refute_nil entry, "BGOVUPD GET on visit #{visit} lists #{ien}: #{listed.inspect}"
    assert_equal "ALLERGY LIST REVIEWED", entry[:action].split("~", 2).last
    assert_equal "A", entry[:kind]

    fields = RpmsRpc::DdrFileman.gets_entry(file: REVIEW_FILE, iens: "#{ien},", fields: ".01;.02;.03;1.02;1204", flags: "IE")[:fields]
    assert_equal "ALLERGY LIST REVIEWED", fields.dig(".01", :external), "V UPDATED/REVIEWED #{ien} action"
    assert_equal DFN.to_s, fields.dig(".02", :internal), "V UPDATED/REVIEWED #{ien} patient"
    assert_equal visit.to_s, fields.dig(".03", :internal), "V UPDATED/REVIEWED #{ien} visit"
    assert_equal client.duz.to_s, fields.dig("1.02", :internal), "V UPDATED/REVIEWED #{ien} entered by"
    assert_equal client.duz.to_s, fields.dig("1204", :internal), "V UPDATED/REVIEWED #{ien} encounter provider"

    puts "\n#{role}: ALLERGY LIST REVIEWED #{ien} on visit #{visit} reads back through BGOVUPD GET and #{REVIEW_FILE}"
  end

  def test_a_visit_of_another_patient_is_refused_unfiled
    visit = open_visit!
    reviews = newest(REVIEW_FILE)
    visits = newest(VISIT_FILE)

    result = RpmsRpc::ClinicalReview.record(OTHER_DFN, visit)

    assert_equal :wrong_patient, result[:error], result.inspect
    assert_equal reviews, newest(REVIEW_FILE), "a refused review added a #{REVIEW_FILE} entry"
    assert_equal visits, newest(VISIT_FILE), "a refused review created a visit"
  end

  private

  # A new ambulatory visit for the synthetic patient, at a time no other
  # spec uses.
  def open_visit!
    now = RpmsRpc::FilemanDateParser.parse_datetime(Array(client.call_rpc("ORWU DT", "NOW")).first.to_s)
    flunk "ORWU DT NOW did not yield a FileMan datetime" unless now
    at = RpmsRpc::FilemanDateParser.format_datetime(now - (rand(30..3000) * 86_400) - (rand(0..59) * 60))
    made = RpmsRpc::Encounter.create(DFN, location_ien: LOCATION_IEN, datetime: at, service_category: "A", create: 1)
    flunk "Encounter.create for DFN #{DFN} answered #{made.inspect}" unless made[:success]
    made[:visit_ien]
  end

  def newest(file)
    listed = RpmsRpc::DdrFileman.lister(file: file, fields: ".01", flags: "IPB", max: "1", xref: "#")
    flunk "DDR LISTER on #{file} failed: #{listed.inspect}" if listed.nil? || listed[:error]
    listed[:entries].first&.dig(:ien).to_i
  end
end

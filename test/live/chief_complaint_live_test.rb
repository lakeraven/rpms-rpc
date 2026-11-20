# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/chief_complaint"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/encounter"
require "rpms_rpc/fileman_date_parser"

# ChiefComplaint.record and .for_visit over BGOCC SET and BGOCC GET, the RPCs
# VueCentric's Triage tab files a chief complaint with (rpms-ux S-TRI-07.1),
# both in CIAV VUECENTRIC. The spec opens an ambulatory visit, records a chief
# complaint on it, reads it back through BGOCC GET and through V NARRATIVE
# TEXT (#9000010.34) with DDR, and checks that a refused visit files nothing.
#
# WRITES against a disposable local container only.
class ChiefComplaintLiveTest < LiveSpec::Test
  runs_as :provider
  writes!

  DFN = 2
  LOCATION_IEN = 6
  NARRATIVE_FILE = "9000010.34"
  NARRATIVE_TYPE_FILE = "9999999.89"

  def test_record_files_the_chief_complaint_on_the_visit_and_reads_back
    visit = open_visit!
    text = "Joint pain and nausea for 4 days, live spec #{role} #{Time.now.utc.strftime('%H%M%S')}"

    result = RpmsRpc::ChiefComplaint.record(visit, text)
    assert result[:success], "ChiefComplaint.record answered #{result.inspect}"
    ien = result[:ien]

    listed = RpmsRpc::ChiefComplaint.for_visit(visit)
    entry = listed.find { |row| row[:ien] == ien }
    refute_nil entry, "BGOCC GET on visit #{visit} lists #{ien}: #{listed.inspect}"
    # GET^BGOCC (patch 25) shows a first line that is not numbered as
    # "1.) Patient complains of ;" and the line; the line is stored as sent.
    assert_equal "1.) Patient complains of ;#{text}", entry[:text]
    assert_equal client.duz.to_i, entry[:author_duz], "the author is the signed-on user"

    row = RpmsRpc::DdrFileman.gets_entry(file: NARRATIVE_FILE, iens: "#{ien},", fields: ".01;.02;.03;1204", flags: "IE")
    fields = row[:fields]
    assert_equal "CHIEF COMPLAINT", fields.dig(".01", :external), "V NARRATIVE TEXT #{ien} type"
    assert_equal DFN.to_s, fields.dig(".02", :internal), "V NARRATIVE TEXT #{ien} patient"
    assert_equal visit.to_s, fields.dig(".03", :internal), "V NARRATIVE TEXT #{ien} visit"
    assert_equal client.duz.to_s, fields.dig("1204", :internal), "V NARRATIVE TEXT #{ien} encounter provider"

    puts "\n#{role}: chief complaint #{ien} on visit #{visit} reads back through BGOCC GET and #{NARRATIVE_FILE}"
  end

  def test_a_visit_that_does_not_exist_is_refused_and_files_nothing
    before = newest(NARRATIVE_FILE)
    result = RpmsRpc::ChiefComplaint.record(999_999_999, "Cough")

    refute result[:success], result.inspect
    assert_equal :refused, result[:error]
    assert_match(/\A-\d+\^/, result[:raw].to_s, "SET^BGOCC refuses with -n^text")
    assert_equal before, newest(NARRATIVE_FILE), "a refused record added a #{NARRATIVE_FILE} entry"
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

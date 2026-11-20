# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/adt"
require "rpms_rpc/api/image"
require "rpms_rpc/api/order"
require "rpms_rpc/api/phr"
require "rpms_rpc/api/note_template"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/dg_sensitive"

# Chart reads VueCentric makes on opening a patient, and the gem wraps, that
# had no live proof: ORWPT INPLOC, ORWRA IMAGING EXAMS1, ORWOR TSALL,
# BEHOCIR GETNUM, BEHOCCD GETREF, TIU TEMPLATE GETITEMS and ACCESS LEVEL,
# DDR KEY VALIDATOR and DG SENSITIVE RECORD ACCESS. DG SENSITIVE RECORD
# ACCESS may write a DG SECURITY LOG entry (DGSEC4.m:65), so the spec is
# declared as writing.
class ChartTabReadsLiveTest < LiveSpec::Test
  runs_as :provider
  writes!

  DFN = 4 # DEMO,PATIENT ONE on the pinned build, an outpatient
  ROOT_TEMPLATE = 1 # TIU TEMPLATE #8927 entry 1, the shared root
  # TIU TEMPLATE FIELD (#8927.1) has a FileMan KEY on its NAME (.01).
  KEY_FILE = "8927.1"

  # CURRLOC^ORWPT answers "0^^" for a patient not admitted (ORWPT.m:222).
  def test_an_outpatient_has_no_current_inpatient_location
    assert_nil RpmsRpc::Adt.current_location(DFN)
  end

  # The first node is the date range searched, BEG^END^MAX (GET^ORWRA's
  # ROOT(-1)), not an exam. The demo build files no radiology exam.
  def test_imaging_exams_are_not_the_searched_date_range
    rows = RpmsRpc::Image.exams_for_patient(DFN)
    rows.each { |row| refute_match(/\A\d{7}\z/, row[:exam_id].to_s, "the date range read as an exam: #{row.inspect}") }
    assert_empty rows, "the demo build has no radiology exam for DFN #{DFN}: #{rows.inspect}"
  end

  def test_order_sheets_are_named_entries
    rows = RpmsRpc::Order.all_sheets
    refute_empty rows, "ORWOR TSALL listed no order sheet"
    rows.each do |row|
      assert_operator row[:ien].to_i, :>, 0
      refute_empty row[:name].to_s
    end
  end

  # GETNUM^BEHOCIR answers TOTAL^RECONCILED; pending is the difference.
  def test_phr_counts_add_up
    counts = RpmsRpc::Phr.counts(DFN)
    assert_equal %i[pending reconciled total], counts.keys.sort
    counts.each_value { |v| assert_operator v, :>=, 0 }
    assert_equal counts[:total], counts[:reconciled] + counts[:pending]
  end

  def test_phr_referrals_for_a_visit_without_one_are_empty
    assert_empty RpmsRpc::Phr.referrals_for_visits([ "999999999" ])
  end

  def test_template_items_are_the_roots_children
    rows = RpmsRpc::NoteTemplate.items(ROOT_TEMPLATE)
    refute_empty rows, "TIU TEMPLATE GETITEMS listed nothing under template #{ROOT_TEMPLATE}"
    rows.each do |row|
      assert_operator row[:ien].to_i, :>, 0
      assert_match(/\A[TGCR]\z/, row[:type].to_s, "template type: #{row.inspect}")
      refute_empty row[:name].to_s
    end
    child = rows.find { |r| r[:type] == "G" && r[:has_children].to_i.positive? } || flunk("no group template with children under #{ROOT_TEMPLATE}")
    refute_empty RpmsRpc::NoteTemplate.items(child[:ien]), "group #{child[:name]} lists no item"
  end

  # TACCESS^TIUSRVT2 (TIUSRVT2.m:3-10) answers 0 full access, 1 read only,
  # 2 no access, or 3 shared-templates editor of the template's owner class.
  def test_template_access_level_is_one_of_the_routines_codes
    item = RpmsRpc::NoteTemplate.items(ROOT_TEMPLATE).first || flunk("no template under #{ROOT_TEMPLATE}")
    assert_includes %w[0 1 2 3], RpmsRpc::NoteTemplate.access_level(item[:ien], client.duz)
  end

  # $$KEYVAL^DIEVK on a FileMan KEY: a new entry named like one on file
  # breaks the key, a new name or the entry itself does not.
  def test_key_validator_finds_a_duplicate_of_a_keyed_field
    listed = RpmsRpc::DdrFileman.lister(file: KEY_FILE, fields: "@;.01", flags: "IP", max: "1")
    entry = listed && listed[:entries]&.first || flunk("DDR LISTER found no #{KEY_FILE} entry")
    name = entry[:pieces].first

    dup = RpmsRpc::DdrFileman.validate_key(values: [ { file: KEY_FILE, iens: "+1,", field: ".01", value: name } ])
    assert_equal({ valid: false, error: nil }, dup, "a second #{name.inspect} breaks the key")
    fresh = RpmsRpc::DdrFileman.validate_key(values: [ { file: KEY_FILE, iens: "+1,", field: ".01", value: "ZZ LIVE KEY #{rand(10**6)}" } ])
    assert_equal({ valid: true, error: nil }, fresh)
    itself = RpmsRpc::DdrFileman.validate_key(values: [ { file: KEY_FILE, iens: "#{entry[:ien]},", field: ".01", value: name } ])
    assert_equal({ valid: true, error: nil }, itself, "the entry does not collide with itself")
  end
end

# PTSEC^DGSEC4 answers 0 (access granted, no warning) for a patient whose
# record is not sensitive. The demo build has no sensitive record. DG
# SENSITIVE RECORD ACCESS is registered only in OR CPRS GUI CHART, which
# PROFILE,MD is not given yet (PROVIDER,TEST was, openrpms#1192).
class ChartTabSensitiveRecordLiveTest < LiveSpec::Test
  runs_as :provider
  needs "OR CPRS GUI CHART", tracked: "openrpms#1276"
  writes!

  def test_sensitive_record_access_to_a_record_that_is_not_sensitive
    assert_equal({ result: 0, messages: [] }, RpmsRpc::DgSensitive.check_access(dfn: ChartTabReadsLiveTest::DFN))
  end
end

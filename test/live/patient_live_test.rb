# frozen_string_literal: true

require_relative "live_helper"
require "date"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/ddr_fileman"

# RpmsRpc::Patient reads against the pinned build (#350): search (ORWPT LIST
# ALL), find (ORWPT SELECT + ORWPT ID INFO), find_by_ssn (ORWPT FULLSSN),
# brief_header (BEHOPTCX PTINFO + BEHOPTPC GETBDP + BEHOCACV CWAD) and contact
# (DDR GETS ENTRY DATA on PATIENT #2). They replace the mock-backed
# patient_test, patient_brief_header_test and patient_contact_test.
#
# Expected values are the demo seed of the pinned build, read off the wire on
# the 0930 build: MOUSE,MICKEY M is DFN 3 (the stock demo patient, also cited
# in mappings/stock_vista.rb from staging), DEMO,PATIENT ONE is DFN 4, and the
# synthetic seed patients are DFNs 9900xx. When the seed changes, a spec fails
# and names what it expected; it never skips.
#
# Every RPC here is in CIAV VUECENTRIC, the option sign-on binds, for PROV123
# and for the programmer alike. These specs read only; they file nothing.
class PatientLiveTest < LiveSpec::Test
  MICKEY = { dfn: 3, name: "MOUSE,MICKEY M", sex: "M", dob: Date.new(1910, 2, 14), ssn: "000009999" }.freeze
  DEMO_ONE = { dfn: 4, name: "DEMO,PATIENT ONE", sex: "F", dob: Date.new(2001, 1, 1), mrn: "99901" }.freeze
  SEED_DFNS = (990_000..990_099)
  PATIENT_FILE = "2"
  HEADER_KEYS = %i[name dob sex mrn age allergy_flag ad_flag primary_provider].freeze

  # -- search (ORWPT LIST ALL) ------------------------------------------------

  def test_search_lists_the_demo_seed_with_each_patients_own_dfn
    rows = RpmsRpc::Patient.search("DEMO")

    assert_includes rows.map { |r| r.slice(:dfn, :name) }, MICKEY.slice(:dfn, :name)
    assert_includes rows.map { |r| r.slice(:dfn, :name) }, DEMO_ONE.slice(:dfn, :name)
    seed = rows.count { |r| SEED_DFNS.cover?(r[:dfn]) }
    assert_operator seed, :>=, 20, "expected the 9900xx seed patients from DEMO on; got #{seed}: is this the pinned build?"
  end

  # ORWPT LIST ALL is a page of the B index from the text on, not a filter
  # (#352): every name collates at or after the text, in index order.
  def test_search_is_a_page_of_names_in_index_order_from_the_text_on
    rows = RpmsRpc::Patient.search("MOUSE")
    names = rows.map { |r| r[:name] }

    assert_equal MICKEY[:name], names.first
    assert_equal names.sort, names, "rows are not in B-index order"
    names.each { |n| assert_operator n, :>=, "MOUSE", "#{n} sorts before the text" }
    assert(names.any? { |n| !n.start_with?("MOUSE") }, "a page from MOUSE on runs past the MOUSE names")
  end

  def test_search_past_the_last_name_is_empty
    assert_equal [], RpmsRpc::Patient.search("ZZZZZ")
  end

  # -- find (ORWPT SELECT merged with ORWPT ID INFO) --------------------------

  def test_find_returns_the_patients_demographics
    found = RpmsRpc::Patient.find(MICKEY[:dfn])

    refute_nil found, "ORWPT SELECT found no patient #{MICKEY[:dfn]}"
    MICKEY.each { |k, v| assert_equal v, found[k], k.to_s }
    assert_equal RpmsRpc::Patient.send(:age_from, MICKEY[:dob]), found[:age], "the age ORWPT SELECT computed"
  end

  # The two RPCs find merges map the same patient independently: SELECT
  # (NAME^SEX^DOB^SSN...) and ID INFO (PID^DOB^SEX^VET^SC%^WARD^RM-BED^NAME).
  # They agree for every seed patient, so a shifted piece in either mapping fails.
  def test_select_and_id_info_agree_for_every_seed_patient
    demo_patients.each do |row|
      dfn = row[:dfn].to_s
      select = RpmsRpc::DataMapper.patient_select.fetch_one(dfn)
      id_info = RpmsRpc::DataMapper.patient_id_info.fetch_one(dfn)
      refute_nil select, "ORWPT SELECT #{dfn}"
      refute_nil id_info, "ORWPT ID INFO #{dfn}"

      assert_equal row[:name], select[:name], "SELECT name for #{dfn}"
      %i[name sex dob ssn].each { |k| assert_equal select[k], id_info[k], "#{k} for #{dfn}" }
      assert_includes %w[M F], select[:sex], "sex for #{dfn}"
      assert_kind_of Date, select[:dob], "dob for #{dfn}"
      assert_match(/\A\d{9}\z/, select[:ssn], "ssn for #{dfn}")
    end
  end

  # IDINFO^ORWPT (ORWPT.m:6-11) answers PID^DOB^SEX^VET^SC%^WARD^RM-BED^NAME
  # (#191). MOUSE,MICKEY M's reply is "000009999^2100214^M^N^^^^MOUSE,MICKEY M":
  # piece 4 is the VETERAN flag, not a race code, and pieces 5-7 are empty for
  # an outpatient, so nothing on this wire is a site IEN.
  def test_find_merges_the_veteran_flag_from_id_info
    found = RpmsRpc::Patient.find(MICKEY[:dfn])

    assert_equal "N", found[:veteran], "piece 4 of ORWPT ID INFO is the VETERAN flag"
    %i[sc_percent ward_location room_bed].each { |k| assert_nil found[k], "#{k}: MOUSE,MICKEY M is an outpatient" }
    refute found.key?(:race_code), "ORWPT ID INFO carries no race code"
    refute found.key?(:site_ien), "ORWPT ID INFO carries no site IEN"
  end

  # No seed patient is admitted, so every one reads with no ward or room-bed,
  # and the veteran flag, when the build has one, is Y or N.
  def test_id_info_reads_every_seed_patient_as_an_outpatient
    demo_patients.each do |row|
      id_info = RpmsRpc::DataMapper.patient_id_info.fetch_one(row[:dfn].to_s)
      assert_includes [ nil, "Y", "N" ], id_info[:veteran], "veteran for #{row[:dfn]}"
      assert_nil id_info[:ward_location], "a seed patient is admitted now (#{row[:dfn]}): assert its ward"
      assert_nil id_info[:room_bed], "room-bed for #{row[:dfn]}"
    end
  end

  def test_find_returns_nil_for_a_dfn_on_no_patient
    assert_nil RpmsRpc::Patient.find(absent_dfn)
  end

  # -- find_by_ssn (ORWPT FULLSSN) --------------------------------------------

  def test_find_by_ssn_finds_the_patient_with_that_ssn
    found = RpmsRpc::Patient.find_by_ssn(MICKEY[:ssn])

    refute_nil found, "ORWPT FULLSSN found nobody for MOUSE,MICKEY M's SSN"
    assert_equal MICKEY.slice(:dfn, :name, :dob, :ssn), found
  end

  # Every seed patient's SSN, read off ORWPT SELECT, finds that patient.
  def test_find_by_ssn_round_trips_every_seed_patient
    demo_patients.each do |row|
      ssn = RpmsRpc::DataMapper.patient_select.fetch_one(row[:dfn].to_s)[:ssn]
      found = RpmsRpc::Patient.find_by_ssn(ssn)
      refute_nil found, "find_by_ssn found nobody for the SSN of #{row[:dfn]}"
      assert_equal row.slice(:dfn, :name), found.slice(:dfn, :name)
    end
  end

  # -- brief_header (BEHOPTCX PTINFO + BEHOPTPC GETBDP + BEHOCACV CWAD) ------

  def test_brief_header_projects_the_chart_banner
    header = RpmsRpc::Patient.brief_header(DEMO_ONE[:dfn])

    refute_nil header, "no chart banner for #{DEMO_ONE[:name]}"
    assert_equal HEADER_KEYS.sort, header.keys.sort, "the issue #60 contract"
    DEMO_ONE.except(:dfn).each { |k, v| assert_equal v, header[k], k.to_s }
    assert_equal RpmsRpc::Patient.send(:age_from, DEMO_ONE[:dob]), header[:age]
  end

  # DEMO,PATIENT ONE's CWAD is "WA": allergies yes, advance directive no. No
  # seed patient has a directive (D) or a designated primary provider
  # (GETBDP is empty for all of them), so those are asserted absent here.
  def test_brief_header_flags_come_from_cwad
    header = RpmsRpc::Patient.brief_header(DEMO_ONE[:dfn])

    assert_equal true, header[:allergy_flag]
    assert_equal false, header[:ad_flag]
    assert_nil header[:primary_provider], "a seed patient has a primary provider now: assert it, and GETBDP's precedence"
  end

  def test_brief_header_agrees_with_find_for_every_seed_patient
    demo_patients.each do |row|
      header = RpmsRpc::Patient.brief_header(row[:dfn])
      found = RpmsRpc::Patient.find(row[:dfn])
      refute_nil header, "no chart banner for #{row[:dfn]}"
      %i[name sex dob].each { |k| assert_equal found[k], header[k], "#{k} for #{row[:dfn]}" }
      refute_empty header[:mrn].to_s, "MRN for #{row[:dfn]}"
      assert_includes [ true, false ], header[:allergy_flag]
    end
  end

  def test_brief_header_is_nil_for_a_dfn_on_no_patient
    assert_nil RpmsRpc::Patient.brief_header(absent_dfn)
  end

  # -- contact (DDR GETS ENTRY DATA, #2 .131/.132/.134/.133) ------------------

  def test_contact_reads_the_patients_telecom
    assert_equal(
      { dfn: 4, phone_home: "907-901-0101", phone_work: "907-910-1010", phone_cell: nil, email: nil },
      RpmsRpc::Patient.contact(DEMO_ONE[:dfn])
    )
    assert_equal(
      { dfn: 3, phone_home: "555-555-5555", phone_work: "555-555-5566", phone_cell: nil, email: nil },
      RpmsRpc::Patient.contact(MICKEY[:dfn])
    )
  end

  def test_contact_is_nil_for_a_dfn_on_no_patient
    assert_nil RpmsRpc::Patient.contact(absent_dfn)
  end

  private

  # The patients listed from DEMO on, MOUSE,MICKEY M and the 9900xx seed.
  def demo_patients
    rows = RpmsRpc::Patient.search("DEMO").select { |r| r[:dfn] == MICKEY[:dfn] || SEED_DFNS.cover?(r[:dfn]) }
    assert_operator rows.size, :>=, 20, "too few seed patients from DEMO on: is this the pinned build?"
    rows
  end

  # A DFN with no PATIENT entry, proven per run through FileMan, not through
  # the RPC under test.
  def absent_dfn
    dfn = 999_999
    reply = RpmsRpc::DdrFileman.gets_entry(file: PATIENT_FILE, iens: "#{dfn},", fields: ".01")
    refute_nil reply, "DDR GETS ENTRY DATA gave no reply"
    assert reply[:error], "DFN #{dfn} is a patient on this build: pick another absent DFN"
    dfn
  end
end

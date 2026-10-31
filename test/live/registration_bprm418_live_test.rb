# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/registration"
require "rpms_rpc/api/ddr_fileman"

# rpms-rpc#418 registration rows on a disposable build: SOGI and MBI writes
# through Registration, read back through DDR; set_sex stays not supported.
class RegistrationBprm418LiveTest < LiveSpec::Test
  writes!

  DFN = 990_043
  MBI = "1EG4TE5MK73"
  MBI_EFFECTIVE = Date.new(2030, 6, 1)

  GI_FILE = "9000001.9401"
  GI_MULT = "9000001.94011"
  SO_FILE = "9000001.9301"
  SO_MULT = "9000001.93011"
  LEGAL_FILE = "9000001.9201"

  MCR_FILE = "9000003"
  MCR_ELIG_FILE = "9000003.11"
  SYNTH_MEDICARE_NUMBER = "LIVESPEC418MCR01"
  ELIG_FIXED_DATE = Date.new(2019, 6, 1)

  def test_set_gender_identity_is_stored_on_the_ihs_patient_sogi_subfiles
    code = pick_code_ien("9999999.104")
    row_date = Date.today
    @restore = -> { purge_gender_identity_rows }

    assert Reg.set_gender_identity(DFN, values: [ code ], date: row_date)[:success]

    header = subfile_row(GI_FILE, DFN, ".01;2", row_date)
    assert header, "no 9000001.9401 row for #{row_date}"

    mult = list_subfile_entries(GI_MULT, "#{header[:ien]},#{DFN},", ".01")
    value_row = mult.find { |e| e[:fields].dig(".01", :internal).to_i == code }
    assert value_row, "no 9000001.94011 row for code #{code}: #{mult.inspect}"
    assert_equal code, value_row[:ien].to_i, "94011 sub-entry IEN should DINUM to the code IEN"
  end

  def test_set_gender_identity_stores_other_text_only_for_the_other_code
    other_code = gender_identity_other_code_ien
    row_date = Date.today
    @restore = -> { purge_gender_identity_rows }

    assert Reg.set_gender_identity(DFN, values: [ other_code ], other: "live spec", date: row_date)[:success]

    header = subfile_row(GI_FILE, DFN, ".01;2", row_date)
    assert header, "no 9000001.9401 row for #{row_date}"
    assert_equal "live spec", header[:fields].dig("2", :internal).to_s.strip
  end

  def test_set_gender_identity_clears_other_text_after_a_rewrite_without_an_oth_value
    other_code = gender_identity_other_code_ien
    code = pick_distinct_gi_code_iens(1).first
    row_date = Date.today
    @restore = -> { purge_gender_identity_rows }

    assert Reg.set_gender_identity(DFN, values: [ other_code ], other: "live spec", date: row_date)[:success]
    result = Reg.set_gender_identity(DFN, values: [ code ], date: row_date)
    assert result[:success], result.inspect

    header = subfile_row(GI_FILE, DFN, ".01;2", row_date)
    assert header, "no 9000001.9401 row for #{row_date}"
    assert_equal "", header[:fields].dig("2", :internal).to_s.strip,
                 "field 2 OTHER should be cleared after a non-OTH rewrite"
  end

  def test_set_gender_identity_refuses_an_unknown_code_ien_and_does_not_create_a_date_row
    row_date = Date.today
    @restore = -> { purge_gender_identity_rows }

    result = Reg.set_gender_identity(DFN, values: [ 424_242 ], date: row_date)
    refute result[:success]
    assert_equal :invalid, result[:error]

    listed = RpmsRpc::DdrFileman.lister(file: GI_FILE, iens: ",#{DFN},", fields: ".01", flags: "IP")
    refute_nil listed
    refute listed[:error]
    target = fm(row_date).to_s
    refute listed[:entries].any? { |e| e[:pieces].first.to_s == target },
           "expected no 9000001.9401 row after :invalid for an unknown code IEN"
  end

  def test_set_gender_identity_on_an_existing_date_replaces_prior_values_without_losing_the_row
    a, b, c = pick_distinct_gi_code_iens(3)
    row_date = Date.today
    @restore = -> { purge_gender_identity_rows }

    assert Reg.set_gender_identity(DFN, values: [ a, b ], date: row_date)[:success]

    result = Reg.set_gender_identity(DFN, values: [ c ], date: row_date)
    assert result[:success], result.inspect

    header = subfile_row(GI_FILE, DFN, ".01;2", row_date)
    assert header, "no 9000001.9401 row for #{row_date}"

    mult = list_subfile_entries(GI_MULT, "#{header[:ien]},#{DFN},", ".01")
    assert_equal 1, mult.length, "expected exactly one 9000001.94011 row: #{mult.inspect}"
    value_row = mult.first
    assert_equal c, value_row[:ien].to_i, "94011 sub-entry IEN should DINUM to the code IEN"
    assert_equal c, value_row[:fields].dig(".01", :internal).to_i
  end

  def test_set_gender_identity_refuses_other_text_beside_a_non_other_code
    code = pick_code_ien("9999999.104")
    code_internal = read_field("9999999.104", "#{code},", "1", "I")
    refute_nil code_internal
    refute_equal "OTH", code_internal.to_s.strip, "pick a non-OTHER code for this assertion"

    row_date = Date.today
    @restore = -> { purge_gender_identity_rows }

    result = Reg.set_gender_identity(DFN, values: [ code ], other: "live spec", date: row_date)
    refute result[:success]
    assert_equal :invalid, result[:error]

    listed = RpmsRpc::DdrFileman.lister(file: GI_FILE, iens: ",#{DFN},", fields: ".01", flags: "IP")
    refute_nil listed
    refute listed[:error]
    target = fm(row_date).to_s
    refute listed[:entries].any? { |e| e[:pieces].first.to_s == target },
           "expected no 9000001.9401 row after :invalid"
  end

  def test_set_sexual_orientation_is_stored_on_the_ihs_patient_sogi_subfiles
    code = pick_code_ien("9999999.103")
    row_date = Date.today
    @restore = -> { purge_sexual_orientation_rows }

    assert Reg.set_sexual_orientation(DFN, values: [ code ], date: row_date)[:success]

    header = subfile_row(SO_FILE, DFN, ".01;2", row_date)
    assert header, "no 9000001.9301 row for #{row_date}"
    mult = list_subfile_entries(SO_MULT, "#{header[:ien]},#{DFN},", ".01")
    value_row = mult.find { |e| e[:fields].dig(".01", :internal).to_i == code }
    assert value_row, "no 9000001.93011 row for code #{code}: #{mult.inspect}"
    assert_equal code, value_row[:ien].to_i, "93011 sub-entry IEN should DINUM to the code IEN"
  end

  def test_set_legal_sex_is_stored_on_the_legal_sex_history_subfile
    source = first_legal_sex_source_ien
    row_date = Date.today
    @restore = -> { purge_legal_sex_rows }

    assert Reg.set_legal_sex(DFN, sex: "X", source: source, date: row_date)[:success]

    got = subfile_row(LEGAL_FILE, DFN, ".01;1;2", row_date)
    assert got, "no 9000001.9201 row for #{row_date}"
    assert_equal "X", got[:fields].dig("1", :internal)
    assert_equal source.to_s, got[:fields].dig("2", :internal)
  end

  def test_add_mbi_is_listed_by_mbis
    @restore = -> { purge_mbi_rows }

    assert Reg.add_mbi(DFN, mbi: MBI, effective_date: MBI_EFFECTIVE, source: 1)[:success]

    rows = Reg.mbis(DFN)
    mine = rows.find { |r| r[:mbi] == MBI }
    assert mine, "MBI not returned by mbis: #{rows.inspect}"
    assert_equal MBI_EFFECTIVE, mine[:effective_date]
    assert_equal 1, mine[:source]
  end

  def test_add_mbi_clears_source_after_a_sourceless_rewrite_on_the_same_effective_date
    @restore = -> { purge_mbi_rows }

    assert Reg.add_mbi(DFN, mbi: MBI, effective_date: MBI_EFFECTIVE, source: 1)[:success]
    result = Reg.add_mbi(DFN, mbi: MBI, effective_date: MBI_EFFECTIVE)
    assert result[:success], result.inspect

    row = subfile_row("9000001.44", DFN, ".01;1;2", MBI_EFFECTIVE)
    assert row, "no 9000001.44 row for #{MBI_EFFECTIVE}"
    assert_equal MBI, row[:fields].dig("1", :internal).to_s.strip
    source = row[:fields].dig("2", :internal)
    assert source.nil? || source.to_s.strip.empty?,
           "field 2 SOURCE should be empty after a sourceless rewrite, got #{source.inspect}"
  end

  def test_set_sex_is_not_supported_and_leaves_sex_and_eligibility_unchanged
    patient_sex = read_field("2", "#{DFN},", ".02", "I")
    refute_nil patient_sex
    refute_empty patient_sex.to_s.strip

    insurer_ien = medicare_insurer_ien
    suffix_ien = first_medicare_suffix_ien
    mcr_ien, elig_ien = file_medicare_eligible!(insurer_ien: insurer_ien, suffix_ien: suffix_ien,
                                                gender: patient_sex)
    @restore = -> { purge_medicare_eligible(mcr_ien) }

    refute_nil mcr_ien
    refute_empty mcr_ien.to_s.strip
    refute_nil elig_ien
    refute_empty elig_ien.to_s.strip

    mcr_row = RpmsRpc::DdrFileman.gets_entry(file: MCR_FILE, iens: "#{mcr_ien},", fields: ".01;.03", flags: "I")
    refute_nil mcr_row, "DDR GETS ENTRY DATA gave no reply for #{MCR_FILE} #{mcr_ien}"
    refute mcr_row[:error], "read failed for #{MCR_FILE} #{mcr_ien}: #{mcr_row.inspect}"
    assert_equal DFN.to_s, mcr_row[:fields].dig(".01", :internal).to_s
    assert_equal SYNTH_MEDICARE_NUMBER, mcr_row[:fields].dig(".03", :internal).to_s.strip

    elig_sex = read_field(MCR_ELIG_FILE, "#{elig_ien},#{mcr_ien},", ".08", "I")
    refute_nil elig_sex
    refute_empty elig_sex.to_s.strip
    assert_equal patient_sex.to_s, elig_sex.to_s

    attempt = patient_sex.to_s.strip.upcase == "M" ? "F" : "M"
    result = Reg.set_sex(DFN, attempt)

    refute result[:success]
    assert_equal :not_supported, result[:error]
    assert_match(/SEXELIG\^AGUTL/i, result[:message])

    after_patient_sex = read_field("2", "#{DFN},", ".02", "I")
    refute_nil after_patient_sex
    refute_empty after_patient_sex.to_s.strip
    assert_equal patient_sex, after_patient_sex

    after_elig_sex = read_field(MCR_ELIG_FILE, "#{elig_ien},#{mcr_ien},", ".08", "I")
    refute_nil after_elig_sex
    refute_empty after_elig_sex.to_s.strip
    assert_equal elig_sex, after_elig_sex
  end

  def teardown
    @restore&.call if client
  ensure
    super
  end

  private

  Reg = RpmsRpc::Registration

  def fm(date) = RpmsRpc::FilemanDateParser.to_fileman(date)

  def read_field(file, iens, field, flags)
    got = RpmsRpc::DdrFileman.gets_entry(file: file, iens: iens, fields: field, flags: flags)
    refute_nil got, "DDR GETS ENTRY DATA gave no reply for #{file} #{iens}"
    refute got[:error], "read failed for #{file} #{iens}"
    got[:fields].dig(field, :internal)
  end

  def subfile_row(file, dfn, fields, row_date)
    listed = RpmsRpc::DdrFileman.lister(file: file, iens: ",#{dfn},", fields: fields, flags: "IP")
    refute_nil listed, "DDR LISTER gave no reply for #{file}"
    refute listed[:error], "DDR LISTER failed for #{file}"

    target = fm(row_date).to_s
    entry = listed[:entries].find { |e| e[:pieces].first.to_s == target }
    refute_nil entry, "no row dated #{row_date} in #{file}: #{listed[:entries].inspect}"

    got = RpmsRpc::DdrFileman.gets_entry(file: file, iens: "#{entry[:ien]},#{dfn},", fields: fields, flags: "I")
    refute_nil got
    refute got[:error]
    { ien: entry[:ien], fields: got[:fields] }
  end

  def list_subfile_entries(file, iens, fields)
    listed = RpmsRpc::DdrFileman.lister(file: file, iens: ",#{iens}", fields: fields, flags: "IP")
    refute_nil listed
    refute listed[:error]
    listed[:entries].map do |entry|
      got = RpmsRpc::DdrFileman.gets_entry(file: file, iens: "#{entry[:ien]},#{iens}", fields: fields, flags: "I")
      refute_nil got
      refute got[:error]
      { ien: entry[:ien], fields: got[:fields] }
    end
  end

  def first_legal_sex_source_ien
    listed = RpmsRpc::DdrFileman.lister(file: "9000030", fields: ".01", flags: "IP", max: 5)
    refute_nil listed
    refute listed[:error]
    refute_empty listed[:entries], "no #9000030 source entries"
    listed[:entries].first[:ien].to_i
  end

  def pick_code_ien(file)
    listed = RpmsRpc::DdrFileman.lister(file: file, fields: ".01", flags: "IP", max: 20)
    refute_nil listed
    refute listed[:error]
    refute_empty listed[:entries], "no rows in #{file}"
    entry = listed[:entries].find { |e| e[:ien].to_i != 1 } || listed[:entries].first
    entry[:ien].to_i
  end

  def pick_distinct_gi_code_iens(count)
    listed = RpmsRpc::DdrFileman.lister(file: "9999999.104", fields: ".01", flags: "IP", max: 50)
    refute_nil listed
    refute listed[:error]
    iens = []
    listed[:entries].each do |entry|
      ien = entry[:ien].to_i
      code = read_field("9999999.104", "#{ien},", "1", "I")
      refute_nil code, "no CODE (field 1) for #9999999.104 IEN #{ien}"
      next if code.to_s.strip == "OTH"

      iens << ien
      break if iens.length >= count
    end
    flunk "need #{count} distinct non-OTHER #9999999.104 IENs, got #{iens.length}" if iens.length < count
    iens
  end

  def gender_identity_other_code_ien
    listed = RpmsRpc::DdrFileman.lister(file: "9999999.104", fields: ".01", flags: "IP", max: 50)
    refute_nil listed
    refute listed[:error]
    listed[:entries].each do |entry|
      code = read_field("9999999.104", "#{entry[:ien]},", "1", "I")
      refute_nil code, "no CODE (field 1) for #9999999.104 IEN #{entry[:ien]}"
      return entry[:ien].to_i if code.to_s.strip == "OTH"
    end
    flunk "no #9999999.104 entry with CODE OTH"
  end

  def purge_gender_identity_rows
    purge_dated_subfile(GI_FILE, DFN)
  end

  def purge_sexual_orientation_rows
    purge_dated_subfile(SO_FILE, DFN)
  end

  def purge_legal_sex_rows
    purge_dated_subfile(LEGAL_FILE, DFN)
  end

  def purge_mbi_rows
    listed = RpmsRpc::DdrFileman.lister(file: "9000001.44", iens: ",#{DFN},", fields: ".01;1", flags: "IP")
    return if listed.nil? || listed[:error]

    listed[:entries].each do |e|
      next unless e[:pieces]&.last.to_s == MBI

      RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: [ { file: "9000001.44", field: ".01", iens: "#{e[:ien]},#{DFN},", value: "@" } ])
    end
  end

  def purge_dated_subfile(file, dfn)
    listed = RpmsRpc::DdrFileman.lister(file: file, iens: ",#{dfn},", fields: ".01", flags: "IP")
    return if listed.nil? || listed[:error]

    listed[:entries].each do |e|
      RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: [ { file: file, field: ".01", iens: "#{e[:ien]},#{dfn},", value: "@" } ])
    end
  end

  def medicare_insurer_ien
    listed = RpmsRpc::DdrFileman.lister(file: "9999999.18", fields: ".01", flags: "IP")
    refute_nil listed, "DDR LISTER gave no reply for #9999999.18"
    refute listed[:error], "DDR LISTER failed for #9999999.18"
    refute_empty listed[:entries], "no #9999999.18 insurer entries"

    entry = listed[:entries].find { |e| e[:pieces].first.to_s.upcase.start_with?("MEDICARE") }
    refute_nil entry, "no MEDICARE insurer in #9999999.18: #{listed[:entries].map { |e| e[:pieces].first }.inspect}"
    entry[:ien]
  end

  def first_medicare_suffix_ien
    listed = RpmsRpc::DdrFileman.lister(file: "9999999.32", fields: ".01", flags: "IP", max: 5)
    refute_nil listed, "DDR LISTER gave no reply for #9999999.32"
    refute listed[:error], "DDR LISTER failed for #9999999.32"
    refute_empty listed[:entries], "no #9999999.32 suffix entries"
    listed[:entries].first[:ien]
  end

  def file_medicare_eligible!(insurer_ien:, suffix_ien:, gender:)
    parent_rows = {
      ".01" => DFN.to_s,
      ".02" => insurer_ien.to_s,
      ".03" => SYNTH_MEDICARE_NUMBER,
      ".04" => suffix_ien.to_s
    }.map do |field, value|
      { file: MCR_FILE, field: field, iens: "+1,", value: value }
    end
    parent = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: parent_rows)
    flunk "DDR FILER could not file #{MCR_FILE}: #{parent.inspect}" unless parent&.dig(:success)

    mcr_ien = parent[:iens].fetch(1)
    elig_iens = "+2,#{mcr_ien},"
    elig_rows = {
      ".01" => fm(ELIG_FIXED_DATE),
      ".03" => "A",
      ".08" => gender.to_s
    }.map do |field, value|
      { file: MCR_ELIG_FILE, field: field, iens: elig_iens, value: value }
    end
    elig = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: elig_rows)
    flunk "DDR FILER could not file #{MCR_ELIG_FILE}: #{elig.inspect}" unless elig&.dig(:success)

    [ mcr_ien, elig[:iens].fetch(2) ]
  end

  def purge_medicare_eligible(mcr_ien)
    RpmsRpc::DdrFileman.filer(mode: "EDIT",
                              rows: [ { file: MCR_FILE, field: ".01", iens: "#{mcr_ien},", value: "@" } ])
  end
end

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

  def test_set_gender_identity_is_stored_on_the_ihs_patient_sogi_subfiles
    code = first_gender_identity_code_ien
    row_date = Date.today
    @restore = -> { purge_gender_identity_rows }

    assert Reg.set_gender_identity(DFN, values: [ code ], other: "live spec", date: row_date)[:success]

    header = subfile_row(GI_FILE, DFN, ".01I;2", row_date)
    assert header, "no 9000001.9401 row for #{row_date}"
    assert_equal "live spec", header[:fields].dig("2", :external).to_s.strip

    mult = list_subfile_entries(GI_MULT, "#{header[:ien]},#{DFN},", ".01I")
    assert_includes mult.map { |e| e[:fields].dig(".01", :internal).to_i }, code
  end

  def test_set_sexual_orientation_is_stored_on_the_ihs_patient_sogi_subfiles
    code = first_sexual_orientation_code_ien
    row_date = Date.today
    @restore = -> { purge_sexual_orientation_rows }

    assert Reg.set_sexual_orientation(DFN, values: [ code ], date: row_date)[:success]

    header = subfile_row(SO_FILE, DFN, ".01I;2", row_date)
    assert header, "no 9000001.9301 row for #{row_date}"
    mult = list_subfile_entries(SO_MULT, "#{header[:ien]},#{DFN},", ".01I")
    assert_includes mult.map { |e| e[:fields].dig(".01", :internal).to_i }, code
  end

  def test_set_legal_sex_is_stored_on_the_legal_sex_history_subfile
    source = first_legal_sex_source_ien
    row_date = Date.today
    @restore = -> { purge_legal_sex_rows }

    assert Reg.set_legal_sex(DFN, sex: "X", source: source, date: row_date)[:success]

    got = subfile_row(LEGAL_FILE, DFN, ".01I;1;2I", row_date)
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

  def test_set_sex_is_not_supported_and_leaves_sex_and_eligibility_unchanged
    patient_sex = read_field("2", "#{DFN},", ".02", "I")
    elig_sex = read_field("9000003.11", ",#{DFN},", ".08", "I")

    result = Reg.set_sex(DFN, "M")

    refute result[:success]
    assert_equal :not_supported, result[:error]
    assert_match(/SEXELIG\^AGUTL/i, result[:message])
    assert_equal patient_sex, read_field("2", "#{DFN},", ".02", "I")
    assert_equal elig_sex, read_field("9000003.11", ",#{DFN},", ".08", "I")
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
    listed = RpmsRpc::DdrFileman.lister(file: file, iens: ",#{iens},", fields: fields, flags: "IP")
    refute_nil listed
    refute listed[:error]
    listed[:entries].map do |entry|
      got = RpmsRpc::DdrFileman.gets_entry(file: file, iens: "#{entry[:ien]},#{iens},", fields: fields, flags: "I")
      { ien: entry[:ien], fields: got[:fields] }
    end
  end

  def first_gender_identity_code_ien
    pick_code_ien("9999999.104")
  end

  def first_sexual_orientation_code_ien
    pick_code_ien("9999999.103")
  end

  def first_legal_sex_source_ien
    listed = RpmsRpc::DdrFileman.lister(file: "9000030", fields: ".01", flags: "IP", max: 5)
    refute_nil listed
    refute listed[:error]
    refute_empty listed[:entries], "no #9000030 source entries"
    listed[:entries].first[:ien].to_i
  end

  def pick_code_ien(file)
    listed = RpmsRpc::DdrFileman.lister(file: file, fields: ".01", flags: "IP", max: 5)
    refute_nil listed
    refute listed[:error]
    refute_empty listed[:entries], "no rows in #{file}"
    listed[:entries].first[:ien].to_i
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
end

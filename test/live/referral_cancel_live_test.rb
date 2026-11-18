# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/referral"
require "rpms_rpc/api/ddr_fileman"

# Referral.cancel files STATUS OF REFERRAL (file 90001, field .15) as X
# (CLOSED-NOT COMPLETED, the code RCIS's reports skip as cancelled) through
# BMC REFERRAL STATUS UPDATE (UPDTSTRF^BMCRPC3, FOIA BMCRPC3.m:176-187), which
# is in the BMCRPC option.
#
# It WRITES, so it runs only against a disposable local container. It needs
# an active referral. The RCIS writer, BMC ADD REFERRAL (SETREFRL^BMCRPC2),
# cannot be called on a YottaDB build: it has 40 formals, the 35th (SNOMED
# preferred term) is required, and YottaDB takes at most 32 actual arguments
# (the broker answers %YDB-E-MAXACTARG). So the spec reuses an active referral
# when one is on file, and otherwise files a minimal one with DDR FILER, the
# stock FileMan filer. Each run cancels the referral, reads the status back
# with DDR GETS ENTRY DATA, and then files it ACTIVE again with the same RPC,
# so the container ends as it began and a rerun reuses the same referral.
class ReferralCancelLiveTest < LiveSpec::Test
  writes!

  REFERRAL_FILE = "90001"
  FIXTURE_DFN = "990001"
  ACTIVE = "A"

  def test_cancel_files_the_cancelled_status_and_the_server_reads_it_back
    ien = active_referral
    begin
      result = RpmsRpc::Referral.cancel(ien)
      assert result[:success], "Referral.cancel(#{ien}) answered #{result.inspect}"
      assert_equal RpmsRpc::Referral::CANCELLED_STATUS, status_of(ien), "referral #{ien} is not cancelled after cancel"
      puts "\n#{persona}: referral #{ien} cancelled, status read back #{status_of(ien).inspect}"
    ensure
      restore_active(ien)
    end
  end

  # BMC REFERRAL STATUS UPDATE checks the IEN and FileMan refuses an entry
  # not on file (UPDTSTRF^BMCRPC3, BMCRPC3.m:181-184). On builds without
  # openrpms#702 the refusal path QUITs with a value under a broker that DOes
  # the tag, so the broker answers an M error at that line instead of
  # "~`0^message". Either way nothing is filed and cancel does not succeed.
  def test_cancel_of_a_referral_not_on_file_is_refused
    begin
      result = RpmsRpc::Referral.cancel("999999999")
      refute result[:success], "cancel of a referral not on file answered success: #{result.inspect}"
    rescue RpmsRpc::Client::RpcError => e
      assert_match(/UPDTSTRF\+\d+\^BMCRPC3/, e.message, "the refusal came from somewhere other than UPDTSTRF^BMCRPC3")
    end
    assert_nil status_of("999999999"), "a referral 999999999 is on file after the refused cancel"
  end

  # Referral.find reads one referral through BMC GET REFERRAL
  # (GTRFBYID^BMCRPC1). The routine finds the record by its REFERRAL #
  # (.02, 13 digits) on the C index (BMCRPC1.m:62-65), so a referral filed
  # without one cannot be read: the fixture gets a number first.
  def test_find_reads_the_referral_by_its_ien
    ien = active_referral
    number = referral_number!(ien)
    record = RpmsRpc::Referral.find(ien)
    refute_nil record, "Referral.find(#{ien}) answered nothing"
    assert_equal ien.to_i, record[:ien].to_i
    assert_equal number, record[:referral_number]
    filed = RpmsRpc::DdrFileman.gets_entry(file: REFERRAL_FILE, iens: "#{ien},", fields: ".03", flags: "I")
    assert_equal filed[:fields].dig(".03", :internal).to_i, record[:patient_dfn], "the patient filed on the referral"
    assert_kind_of Array, record[:diagnoses]
    assert_equal [ "N", "O" ], record.values_at(:type, :visit_type), "in-house (.04) and outpatient (.14), as filed"
    puts "\n#{persona}: Referral.find(#{ien}) read referral #{number} of DFN #{record[:patient_dfn]}"
  end

  # GTRFBYID^BMCRPC1 answers "Not a valid Referral Ien" as a scalar under a
  # GLOBAL ARRAY RPC (BMCRPC1.m:57), so the broker raised an M error reading
  # it as a global name (#767). find answers nil instead.
  def test_find_of_a_referral_not_on_file_answers_nil
    assert_nil status_of("999999999"), "a referral 999999999 is on file"
    assert_nil RpmsRpc::Referral.find("999999999")
  end

  # A referral with no REFERRAL # (.02) is one RCIS never files, and
  # GTRFBYID^BMCRPC1 cannot read it: it looks the record up by .02 on the C
  # index, finds nothing and dies with GVUNDEF ^TMP($J,"PRNRC",1) (#767).
  # find answers nil. The spec files one with DDR FILER and deletes it.
  def test_find_of_a_referral_with_no_number_answers_nil
    ien = file_fixture
    begin
      entry = RpmsRpc::DdrFileman.gets_entry(file: REFERRAL_FILE, iens: "#{ien},", fields: ".02", flags: "I")
      assert_equal "", entry[:fields].dig(".02", :internal).to_s, "the fixture referral #{ien} has a REFERRAL #"
      assert_nil RpmsRpc::Referral.find(ien)
    ensure
      delete_referral(ien)
    end
  end

  def test_cancel_of_a_non_ien_answers_without_the_wire
    refute RpmsRpc::Referral.cancel(nil)[:success]
    refute RpmsRpc::Referral.cancel("0")[:success]
  end

  private

  # The referral's REFERRAL # (.02), filed when it has none.
  def referral_number!(ien)
    entry = RpmsRpc::DdrFileman.gets_entry(file: REFERRAL_FILE, iens: "#{ien},", fields: ".02", flags: "I")
    number = entry && !entry[:error] ? entry[:fields].dig(".02", :internal).to_s : ""
    return number unless number.empty?

    number = format("9%012d", Integer(ien))
    filed = RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: [ { file: REFERRAL_FILE, field: ".02", iens: "#{ien},", value: number } ])
    assert filed && filed[:success], "DDR FILER could not file REFERRAL # on #{ien}: #{filed.inspect}"
    number
  end

  # STATUS OF REFERRAL, internal, or nil when the entry is not on file.
  def status_of(ien)
    entry = RpmsRpc::DdrFileman.gets_entry(file: REFERRAL_FILE, iens: "#{ien},", fields: ".15", flags: "I")
    flunk "DDR GETS ENTRY DATA on file #{REFERRAL_FILE} gave no reply" if entry.nil?
    return nil if entry[:error]

    entry[:fields].dig(".15", :internal)
  end

  def active_referral
    listed = RpmsRpc::DdrFileman.lister(file: REFERRAL_FILE, fields: "@;.15", flags: "IP")
    flunk "DDR LISTER on file #{REFERRAL_FILE} gave no reply" if listed.nil?
    flunk "DDR LISTER on file #{REFERRAL_FILE} answered an error" if listed[:error]

    found = listed[:entries].find { |e| e[:pieces].first == ACTIVE }
    found ? found[:ien] : file_fixture
  end

  # A minimal ACTIVE referral (date, patient, in-house, outpatient), filed
  # with DDR FILER because BMC ADD REFERRAL cannot be called on YottaDB.
  def file_fixture
    values = { ".01" => today_fileman, ".03" => FIXTURE_DFN, ".04" => "N", ".14" => "O", ".15" => ACTIVE }
    rows = values.map { |field, value| { file: REFERRAL_FILE, field: field, iens: "+1,", value: value } }
    filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: rows)
    assert filed && filed[:success], "DDR FILER could not file a fixture referral: #{filed.inspect}"
    filed[:iens].fetch(1)
  end

  # FileMan deletes an entry when its .01 is filed as "@".
  def delete_referral(ien)
    rows = [ { file: REFERRAL_FILE, field: ".01", iens: "#{ien},", value: "@" } ]
    deleted = RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: rows)
    assert deleted && deleted[:success], "DDR FILER could not delete fixture referral #{ien}: #{deleted.inspect}"
    assert_nil status_of(ien), "fixture referral #{ien} is still on file after the delete"
  end

  def today_fileman
    d = Date.today
    format("%<y>03d%<m>02d%<d>02d", y: d.year - 1700, m: d.month, d: d.day)
  end

  def restore_active(ien)
    client.with_context(RpmsRpc::Referral::CONTEXT) { RpmsRpc::Referral.update_status(ien, ACTIVE) }
    assert_equal ACTIVE, status_of(ien), "referral #{ien} could not be filed ACTIVE again; the container is left with it cancelled"
  end
end

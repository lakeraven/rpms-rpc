# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/tribal"

# CiaClient#call_rpc returns reply LINES and raises a broker refusal, as
# XwbClient and BmxClient do (#195). It used to return printable(raw): the
# sequence echo and ack became leading text, CR/LF became spaces and the
# \x01 error flag became data. Every DataMapper fetch_* read goes through
# call_rpc, so on a CIA broker:
#
#   - ORWPT LIST ALL came back as ONE patient: the frame byte as the DFN and
#     the first row's name, a wrong-patient pairing;
#   - ORWPT FULLSSN for an SSN on no patient came back as a match;
#   - ORWU USERKEYS, not registered on the build, came back as the user's one
#     security key (its refusal text);
#   - DDR LISTER rows lost their names (Tribal.tribes also asked LIST^DIC for
#     no fields, so the rows were bare IENs).
#
# These specs read only; they file nothing.
class CiaReplyLinesLiveTest < LiveSpec::Test
  # Not the SSN of any patient on file: proven per run through the SSN
  # cross-reference (DDR LISTER on file #2), not through ORWPT FULLSSN.
  ABSENT_SSN = "999999998"
  PATIENT_FILE = "2"

  # Not registered on the build (#207).
  UNREGISTERED_RPC = "ORWU USERKEYS"

  def test_a_patient_list_parses_one_patient_per_row_each_with_its_own_dfn
    rows = RpmsRpc::Patient.search("DEMO")

    assert_operator rows.size, :>, 1, "a list of one row is what the flattened reply produced"
    rows.each do |r|
      assert_kind_of Integer, r[:dfn], "row #{r.inspect}"
      assert_operator r[:dfn], :>, 0, "row #{r.inspect}"
      refute_empty r[:name].to_s.strip, "row #{r.inspect}"
    end
    dfns = rows.map { |r| r[:dfn] }
    assert_equal dfns.uniq, dfns, "two rows carry one DFN"

    rows.each do |r|
      found = RpmsRpc::Patient.find(r[:dfn])
      refute_nil found, "ORWPT SELECT found no patient #{r[:dfn]}"
      assert_equal r[:name], found[:name], "the list paired DFN #{r[:dfn]} with another patient's name"
    end
  end

  def test_call_rpc_lines_is_the_same_lines_as_call_rpc
    assert_equal client.call_rpc("ORWPT LIST ALL", "DEMO", "1"),
                 client.call_rpc_lines("ORWPT LIST ALL", "DEMO", "1")
  end

  def test_an_ssn_on_no_patient_finds_no_patient
    _, on_file = patient_with_ssn
    refute_empty ssn_xref(on_file), "the SSN cross-reference does not find an SSN on file, so it proves nothing"
    assert_empty ssn_xref(ABSENT_SSN), "#{ABSENT_SSN} is on file here; pick another absent SSN"

    assert_nil RpmsRpc::Patient.find_by_ssn(ABSENT_SSN)
  end

  def test_an_ssn_on_file_finds_that_patient
    patient, ssn = patient_with_ssn

    found = RpmsRpc::Patient.find_by_ssn(ssn)

    refute_nil found, "find_by_ssn found no patient for an SSN on file"
    assert_equal patient[:dfn], found[:dfn]
    assert_equal patient[:name], found[:name]
    assert_equal ssn, found[:ssn]
  end

  # The lowest public API that sends an arbitrary RPC name is
  # Client#call_rpc. The refusal is the typed RpcNotAvailableError (#363);
  # missing_rpc_live_test.rb holds the rest of that contract.
  def test_an_unregistered_rpc_is_a_refusal_never_data
    err = assert_raises(RpmsRpc::Client::RpcNotAvailableError) { client.call_rpc(UNREGISTERED_RPC, client.duz.to_s) }
    assert_match(/Unknown remote procedure: #{UNREGISTERED_RPC}/, err.message)
  end

  def test_a_lister_page_carries_each_rows_name
    tribes = RpmsRpc::Tribal.tribes(part: "A")

    refute_nil tribes
    assert_operator tribes.size, :>, 1
    tribes.each do |t|
      assert_operator t[:ien].to_i, :>, 0, "row #{t.inspect}"
      assert t[:name].to_s.start_with?("A"), "row #{t.inspect} is not a name the page was asked for"
    end
    assert_equal tribes.map { |t| t[:ien] }.uniq.size, tribes.size, "two rows carry one IEN"
  end

  private

  # The first DEMO patient with an SSN on file. None is missing seed data,
  # not a reason to pass: the spec fails and says so.
  def patient_with_ssn
    rows = RpmsRpc::Patient.search("DEMO")
    refute_empty rows, "no patient from DEMO on: this build has no demo patients to read"
    rows.each do |row|
      ssn = RpmsRpc::Patient.find(row[:dfn])&.dig(:ssn).to_s
      return [ row, ssn ] unless ssn.empty?
    end
    flunk "none of the #{rows.size} DEMO patients has an SSN on file; file one on a patient " \
          "(file #2, field .09) on the container, or point the spec at a build whose demo data has one"
  end

  # Patients whose SSN cross-reference entry is exactly this SSN.
  def ssn_xref(ssn)
    listing = RpmsRpc::DdrFileman.lister(file: PATIENT_FILE, xref: "SSN", part: ssn)
    refute_nil listing, "DDR LISTER gave no reply"
    refute listing[:error], "DDR LISTER on the SSN cross-reference: #{listing.inspect}"
    listing[:entries]
  end
end

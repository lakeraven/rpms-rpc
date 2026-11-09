# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/coverage"
require_relative "../captured_replies"

# RpmsRpc::Coverage.delete_private_insurance (rpms-rpc#382): verify ownership on
# #9000006.11 with one DDR GETS ENTRY DATA read, one DDR FILER "@" row, confirm
# absence with a DDR LISTER of the patient's policy rows; never AGG UPDATE
# PRIVATE INSUR PROC D.
#
# The replies are the build's (test/fixtures/captured_replies/coverage.yml):
# a policy filed for demo patient 990048 by add_private_insurance, then deleted
# as PROFILE,REG on a throwaway container, recorded as flows and replayed
# through CiaClient.
#
# Not captured, so not tested here: a filer error, an owner read or lister that
# errors or does not answer, a lister that still lists the record after the
# delete, and the v1 packed lister shape. The build sent none of these; they
# were tested against replies written by hand, which ADR 0009 retires.
class CoveragePrivateDeleteTest < Minitest::Test
  SLUG = "coverage"
  Cov = RpmsRpc::Coverage
  Ddr = RpmsRpc::DdrFileman

  PRIVATE_FILE = "9000006.11"
  PRIVATE_AGG_RPC = "AGG UPDATE PRIVATE INSUR"
  FILEMAN_CONTEXT = "CIAV VUECENTRIC"

  DFN = "990048"
  OTHER_DFN = "990049"
  RECORD = "1"

  def teardown
    RpmsRpc.reset!
  end

  def replay(script = {})
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def replay_flow(name) = replay(CapturedReplies.flow_script(SLUG, name))

  def rpcs(client) = client.rpcs_called.grep(String)

  def expected_lister_param(dfn = DFN)
    Ddr.lister_param(file: PRIVATE_FILE, iens: ",#{dfn},", fields: "@;.01", flags: "IP", max: "*", xref: "#")
  end

  def test_delete_files_one_at_row_after_one_owner_read_and_confirms_with_lister
    client = replay_flow("delete_private")

    result = Cov.delete_private_insurance(DFN, record_ien: RECORD)

    assert_equal({ success: true, record_ien: RECORD }, result)
    assert_equal [ "DDR GETS ENTRY DATA", "DDR FILER", "DDR LISTER" ], rpcs(client)
    calls = client.calls.reject { |c| c[:rpc] == :create_context }
    assert_equal [ { "FILE" => PRIVATE_FILE, "IENS" => "#{RECORD},#{DFN},", "FIELDS" => ".01", "FLAGS" => "I" } ],
                 calls[0][:params]
    assert_equal({ 1 => "#{PRIVATE_FILE}^.01^#{RECORD},#{DFN},^@" }, calls[1][:params][1])
    assert_equal expected_lister_param.to_h, calls[2][:params].first
    assert_equal FILEMAN_CONTEXT, client.current_context
    assert_equal CapturedReplies.flow_calls(SLUG, "delete_private"), calls.map { |c| [ c[:rpc], c[:params] ] }
  end

  # A record that is not on file under that patient (the build answers the
  # owner read with an error block, and the patient's list omits it) is
  # already absent: nothing is filed.
  def test_a_record_not_on_file_for_the_patient_is_already_absent_without_a_filer
    client = replay_flow("delete_private_other_patient")

    result = Cov.delete_private_insurance(OTHER_DFN, record_ien: RECORD)

    assert_equal :already_absent, result[:error]
    refute result[:success]
    assert_equal [ "DDR GETS ENTRY DATA", "DDR LISTER" ], rpcs(client)
  end

  def test_a_repeat_delete_is_already_absent_without_a_second_filer
    client = replay_flow("delete_private_again")

    result = Cov.delete_private_insurance(DFN, record_ien: RECORD)

    assert_equal({ success: false, error: :already_absent, message: "private insurance 1 is not on file for patient 990048",
                   record_ien: RECORD }, result)
    refute_includes rpcs(client), "DDR FILER"
  end

  def test_delete_never_calls_agg_update_private_insur
    client = replay_flow("delete_private")

    Cov.delete_private_insurance(DFN, record_ien: RECORD)

    refute_includes rpcs(client), PRIVATE_AGG_RPC
  end

  # add_private_insurance with no end date sends both end-date fields blank:
  # UPOL^AGGUPPVT reads AGGPHEED bare, and without it the build filed the
  # policy, then died before the result row, and the gem reported a failure a
  # retry would answer with a second policy (rpms-rpc#688). With them, the
  # build answers its result row and the gem reports the record it filed.
  def test_add_private_insurance_without_an_end_date_sends_them_blank_and_reports_the_record
    client = replay_flow("add_private")

    result = Cov.add_private_insurance(DFN, insurer_ien: "1", policy_holder: "ZZCOV,HOLDER", member_number: "ZZ0001",
                                            effective_on: "11/01/2026")

    assert_equal({ success: true, error: nil, record_ien: RECORD, policy_holder_ien: "1" }, result)
    parms = client.calls.find { |c| c[:rpc] == PRIVATE_AGG_RPC }[:params].last
    assert_equal %w[AGGPIINS=1 AGGPIHLN=ZZCOV,HOLDER AGGPIMBN=ZZ0001 AGGPIESD=11/01/2026 AGGPIEED=
                    AGGPHESD=11/01/2026 AGGPHEED=], parms.split("\x1C")
  end

  # Only a missing end date goes blank: any other value that is not a real date
  # is refused before anything is sent, never filed as an open-ended policy.
  def test_add_private_insurance_refuses_an_end_date_that_is_not_a_date
    client = replay

    [ false, "13/01/2027", "soon" ].each do |bad|
      assert_raises(ArgumentError, "ends_on: #{bad.inspect}") do
        Cov.add_private_insurance(DFN, insurer_ien: "1", policy_holder: "ZZCOV,HOLDER", member_number: "ZZ0001",
                                       effective_on: "11/01/2026", ends_on: bad)
      end
    end
    assert_empty rpcs(client)
  end

  # ...and the policy it reports is the one on file, with no end date.
  def test_the_policy_reads_back_on_file
    replay_flow("on_file_private")

    policy = Cov.on_file(DFN)[:private].first

    assert_equal({ record_ien: RECORD, payer: "RAILROAD RETIREMENT", payer_ien: "1", number: "ZZ0001",
                   policy_holder: "ZZCOV,HOLDER", starts_on: Date.new(2026, 11, 1), ends_on: nil, active: true }, policy)
  end

  # -- guards: nothing reaches the wire ----------------------------------------

  def test_delete_rejects_a_bad_record_ien_before_wire
    client = replay

    [ "", "0", "-1", "1.5", "abc", "7^1", "7,1", "7&1", "7[1", "7]1" ].each do |bad|
      assert_raises(ArgumentError) { Cov.delete_private_insurance(DFN, record_ien: bad) }
    end
    assert_empty client.calls
  end

  def test_delete_with_an_invalid_dfn_returns_nil_with_no_calls
    client = replay

    [ nil, "", "0", "-1", "abc", "990049^1", "990049,1", "990049&1", "990049[1", "990049]1", "^", ",", "&", "[", "]" ].each do |bad|
      assert_nil Cov.delete_private_insurance(bad, record_ien: RECORD)
    end
    assert_empty client.calls
  end
end

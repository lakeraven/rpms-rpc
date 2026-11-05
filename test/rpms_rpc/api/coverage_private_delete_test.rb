# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/coverage"

# Hermetic contract for RpmsRpc::Coverage.delete_private_insurance (rpms-rpc#382):
# verify ownership on #9000006.11 with one DDR GETS ENTRY DATA read, one DDR FILER
# "@" row, confirm absence with a DDR LISTER of the patient's policy rows — never
# AGG UPDATE PRIVATE INSUR PROC D.
class CoveragePrivateDeleteTest < Minitest::Test
  Cov = RpmsRpc::Coverage
  Ddr = RpmsRpc::DdrFileman

  PRIVATE_FILE = "9000006.11"
  PRIVATE_AGG_RPC = "AGG UPDATE PRIVATE INSUR"
  FILEMAN_CONTEXT = "CIAV VUECENTRIC"

  DFN = "990049"
  RECORD = "7"

  class RecordingClient
    include RpmsRpc::ContextScope

    attr_reader :calls

    def initialize(replies = {})
      @replies = replies
      @sequences = Hash.new { |h, k| h[k] = [] }
      @calls = []
      @current_context = RpmsRpc::MockClient::DEFAULT_CONTEXT
    end

    def create_context(name)
      @current_context = name
      true
    end

    def current_context = @current_context

    def queue(key, *bodies)
      @sequences[key].concat(bodies)
    end

    def call_rpc(rpc, *params)
      @calls << [ rpc, *params, @current_context ]
      body = dequeue_reply(rpc, params)
      return [] if body.nil?

      body.is_a?(Array) ? body : body.to_s.split(/\r?\n/)
    end

    def call_rpc_global_array(rpc, *params)
      @calls << [ rpc, *params.map(&:to_s), @current_context ]
      body = dequeue_reply(rpc, params.map(&:to_s))
      body || ""
    end

    private

    def dequeue_reply(rpc, params)
      key = reply_key(rpc, params)
      @sequences[key].shift || @replies[key] || @replies[rpc]
    end

    def reply_key(rpc, params)
      case rpc
      when "DDR GETS ENTRY DATA", "DDR FILER", "DDR LISTER"
        [ rpc, params.first.to_s ].join("\0")
      else
        [ rpc, *params.map(&:to_s) ].join("\0")
      end
    end
  end

  def setup
    RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  def gets_key(record_ien, dfn)
    param = Ddr.gets_entry_param(file: PRIVATE_FILE, iens: "#{record_ien},#{dfn},", fields: ".01", flags: "I")
    [ "DDR GETS ENTRY DATA", param.to_s ].join("\0")
  end

  def lister_key(dfn = DFN, **overrides)
    param = Ddr.lister_param(file: PRIVATE_FILE, iens: ",#{dfn},", fields: ".01", max: "*", **overrides)
    [ "DDR LISTER", param.to_s ].join("\0")
  end

  def seed_owner!(client, record_ien: RECORD, dfn: DFN, insurer_ien: "5")
    key = gets_key(record_ien, dfn)
    body = "[Data]\n#{PRIVATE_FILE}^#{record_ien},#{dfn},^.01^#{insurer_ien}^#{insurer_ien}\n"
    client.instance_eval { @replies[key] = body }
  end

  def seed_empty_owner!(client, record_ien: RECORD, dfn: DFN)
    key = gets_key(record_ien, dfn)
    body = "[Data]\n#{PRIVATE_FILE}^#{record_ien},#{dfn},^.01^^\n"
    client.instance_eval { @replies[key] = body }
  end

  def seed_absent_gets!(client, record_ien: RECORD, dfn: DFN)
    key = gets_key(record_ien, dfn)
    client.instance_eval { @replies[key] = "[Errors]\n" }
  end

  def seed_filer_ok!(client)
    key = [ "DDR FILER", "EDIT" ].join("\0")
    client.instance_eval { @replies[key] = "[Data]\n" }
  end

  def seed_filer_fail!(client, message: "The entry does not exist.")
    key = [ "DDR FILER", "EDIT" ].join("\0")
    body = "[Data]\n[BEGIN_diERRORS]\n701^1^.01^#{PRIVATE_FILE}\n#{message}\n[END_diERRORS]"
    client.instance_eval { @replies[key] = body }
  end

  def seed_lister!(client, body, dfn: DFN, **overrides)
    key = lister_key(dfn, **overrides)
    client.instance_eval { @replies[key] = body }
  end

  def ddr_gets_calls(client)
    client.calls.select { |call| call.first == "DDR GETS ENTRY DATA" }
  end

  def filer_calls(client)
    client.calls.select { |call| call.first == "DDR FILER" }
  end

  def lister_calls(client)
    client.calls.select { |call| call.first == "DDR LISTER" }
  end

  def agg_private_calls(client)
    client.calls.select { |call| call.first == PRIVATE_AGG_RPC }
  end

  def ddr_call_order(client)
    client.calls.map(&:first).grep(/\AD(?:DR GETS ENTRY DATA|DR FILER|DR LISTER)\z/)
  end

  def expected_lister_param(dfn = DFN)
    Ddr.lister_param(file: PRIVATE_FILE, iens: ",#{dfn},", fields: ".01", max: "*")
  end

  def test_delete_private_insurance_files_one_at_row_after_one_owner_read_and_confirms_with_lister
    client = RecordingClient.new
    seed_owner!(client)
    seed_filer_ok!(client)
    seed_lister!(client, "[Data]\n8^5")

    result = Cov.delete_private_insurance(DFN, record_ien: RECORD, client: client)

    assert_equal({ success: true, record_ien: RECORD }, result)
    assert_equal 1, ddr_gets_calls(client).size
    assert_equal 1, filer_calls(client).size
    rows = filer_calls(client).first[2]
    assert_equal({ 1 => "#{PRIVATE_FILE}^.01^#{RECORD},#{DFN},^@" }, rows)
    assert_equal 1, lister_calls(client).size
    assert_equal expected_lister_param, lister_calls(client).first[1]
    assert_equal [ "DDR GETS ENTRY DATA", "DDR FILER", "DDR LISTER" ], ddr_call_order(client)
    ddr = client.calls.select { |call| call.first.start_with?("DDR") }
    assert(ddr.all? { |call| call.last == FILEMAN_CONTEXT }, "every DDR call runs in #{FILEMAN_CONTEXT}")
    assert_empty agg_private_calls(client)
  end

  def test_delete_private_insurance_refuses_when_the_row_is_not_verified_for_the_patient
    client = RecordingClient.new
    seed_empty_owner!(client)

    result = Cov.delete_private_insurance(DFN, record_ien: RECORD, client: client)

    refute result[:success]
    assert_equal :verification_failed, result[:error]
    assert_empty filer_calls(client)
    assert_empty lister_calls(client)
    assert_empty agg_private_calls(client)
  end

  def test_delete_private_insurance_fails_closed_when_the_owner_read_does_not_answer
    client = RecordingClient.new

    result = Cov.delete_private_insurance(DFN, record_ien: RECORD, client: client)

    refute result[:success]
    assert_equal :verification_failed, result[:error]
    assert_empty filer_calls(client)
    assert_empty lister_calls(client)
    assert_empty agg_private_calls(client)
  end

  def test_delete_private_insurance_fails_closed_when_the_owner_read_errors
    client = RecordingClient.new
    seed_absent_gets!(client)

    result = Cov.delete_private_insurance(DFN, record_ien: RECORD, client: client)

    refute result[:success]
    assert_equal :verification_failed, result[:error]
    assert_empty filer_calls(client)
    assert_empty lister_calls(client)
    assert_empty agg_private_calls(client)
  end

  def test_delete_private_insurance_fails_when_lister_still_lists_the_record
    client = RecordingClient.new
    seed_owner!(client)
    seed_filer_ok!(client)
    seed_lister!(client, "[Data]\n#{RECORD}^5\n8^5")

    result = Cov.delete_private_insurance(DFN, record_ien: RECORD, client: client)

    refute result[:success]
    assert_equal :verification_failed, result[:error]
    assert_equal 1, filer_calls(client).size
    assert_equal 1, lister_calls(client).size
    assert_empty agg_private_calls(client)
  end

  def test_delete_private_insurance_fails_closed_when_post_delete_lister_gives_no_reply
    client = RecordingClient.new
    seed_owner!(client)
    seed_filer_ok!(client)

    result = Cov.delete_private_insurance(DFN, record_ien: RECORD, client: client)

    refute result[:success]
    assert_equal :verification_failed, result[:error]
    assert_equal 1, filer_calls(client).size
    assert_equal 1, lister_calls(client).size
    assert_empty agg_private_calls(client)
  end

  def test_delete_private_insurance_fails_closed_when_post_delete_lister_errors
    client = RecordingClient.new
    seed_owner!(client)
    seed_filer_ok!(client)
    seed_lister!(client, "[Data]\n[Errors]")

    result = Cov.delete_private_insurance(DFN, record_ien: RECORD, client: client)

    refute result[:success]
    assert_equal :verification_failed, result[:error]
    assert_equal 1, filer_calls(client).size
    assert_equal 1, lister_calls(client).size
    assert_empty agg_private_calls(client)
  end

  def test_delete_private_insurance_fails_closed_when_post_delete_lister_has_no_data_section
    client = RecordingClient.new
    seed_owner!(client)
    seed_filer_ok!(client)
    seed_lister!(client, "[Misc]\nMORE^POLICY,OTHER^42")

    result = Cov.delete_private_insurance(DFN, record_ien: RECORD, client: client)

    refute result[:success]
    assert_equal :verification_failed, result[:error]
    assert_equal 1, filer_calls(client).size
    assert_equal 1, lister_calls(client).size
    assert_empty agg_private_calls(client)
  end

  def test_delete_private_insurance_fails_closed_when_post_delete_lister_has_more_continuation
    client = RecordingClient.new
    seed_owner!(client)
    seed_filer_ok!(client)
    seed_lister!(client, "[Misc]\nMORE^POLICY,OTHER^8\n[Data]\n6^5")

    result = Cov.delete_private_insurance(DFN, record_ien: RECORD, client: client)

    refute result[:success]
    assert_equal :verification_failed, result[:error]
    assert_equal 1, filer_calls(client).size
    assert_equal 1, lister_calls(client).size
    assert_empty agg_private_calls(client)
  end

  def test_delete_private_insurance_surfaces_filer_errors_as_delete_failed
    client = RecordingClient.new
    seed_owner!(client)
    seed_filer_fail!(client)

    result = Cov.delete_private_insurance(DFN, record_ien: RECORD, client: client)

    refute result[:success]
    assert_equal :delete_failed, result[:error]
    assert_includes result[:message].to_s, "does not exist"
    assert_equal 1, filer_calls(client).size
    assert_empty lister_calls(client)
    assert_empty agg_private_calls(client)
  end

  def test_delete_private_insurance_rejects_bad_record_ien_before_wire
    client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = client }

    [ "", "0", "-1", "1.5", "abc" ].each do |bad|
      assert_raises(ArgumentError) { Cov.delete_private_insurance(DFN, record_ien: bad, client: client) }
    end
    assert_empty client.calls
  end

  def test_delete_private_insurance_invalid_dfn_returns_nil_with_no_calls
    client = RecordingClient.new

    [ nil, "", "0", "-1", "abc" ].each do |bad|
      assert_nil Cov.delete_private_insurance(bad, record_ien: RECORD, client: client)
    end
    assert_empty client.calls
  end

  def test_delete_private_insurance_never_calls_agg_update_private_insur_on_success
    client = RecordingClient.new
    seed_owner!(client)
    seed_filer_ok!(client)
    seed_lister!(client, "[Data]")

    Cov.delete_private_insurance(DFN, record_ien: RECORD, client: client)

    assert_empty agg_private_calls(client)
  end
end

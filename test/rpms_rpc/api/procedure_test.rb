# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/procedure"
require_relative "../captured_replies"

# Procedure reads the BGOVCPT replies a fresh rpms-ydb container sent
# (test/fixtures/captured_replies/bgovcpt.yml), replayed through CiaClient.
# test/live/procedure_live_test.rb proves the read against the V CPT file.
#
# Procedure.add has no proven write: it sends three parameters to
# SET^BGOVCPT(RET,INP), which takes one, and the build refuses the frame
# (ACTLSTTOOLONG). rpms-rpc#524 tracks sending the layout SET expects; until
# then this file pins that the refusal reaches the caller, and the guards
# that send nothing.
class ProcedureTest < Minitest::Test
  SLUG = "bgovcpt"
  DFN       = "4"
  VISIT_IEN = "4"
  CPT       = "99213"

  def teardown
    RpmsRpc.reset!
  end

  def replay(script)
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def capture(name) = CapturedReplies.raw(SLUG, name)
  def sent(name) = CapturedReplies.file(SLUG).fetch("captures").find { |c| c["name"] == name }.fetch("inputs")

  def test_for_patient_reads_each_v_cpt_row_with_its_visit_date
    client = replay("BGOVCPT GET" => [ capture("dfn_4") ])

    rows = RpmsRpc::Procedure.for_patient(DFN)

    assert_equal 7, rows.size
    assert_equal({ ien: "1", visit_ien: "4", date: Date.new(2026, 9, 2), cpt_code: "B9999",
                   name: "Parenteral supp not othrws c", quantity: 1, provider: "MANAGER,SYSTEM",
                   facility: "DEMO IHS CLINIC" },
                 rows.first.slice(:ien, :visit_ien, :date, :cpt_code, :name, :quantity, :provider, :facility))
    assert_equal [ { rpc: "BGOVCPT GET", params: [ DFN ] } ], client.calls
  end

  def test_for_patient_of_a_blank_or_non_positive_dfn_is_empty_without_a_call
    client = replay({})

    [ nil, "", "0", "-1" ].each { |dfn| assert_equal [], RpmsRpc::Procedure.for_patient(dfn) }
    assert_empty client.calls
  end

  # rpms-rpc#524: the build refuses Procedure.add's frame. The refusal is
  # raised, never read as a saved entry.
  def test_add_raises_the_builds_refusal_of_its_frame
    client = replay("BGOVCPT SET" => [ capture("set_three_params") ])

    error = assert_raises(RpmsRpc::Client::RpcMError) do
      RpmsRpc::Procedure.add(DFN, VISIT_IEN, CPT, narrative: "office visit")
    end
    assert_match(/ACTLSTTOOLONG/, error.message)
    assert_equal [ { rpc: "BGOVCPT SET", params: sent("set_three_params") } ], client.calls,
                 "add sends the frame the capture was refused for"
  end

  def test_blank_args_return_failure_without_a_call
    client = replay({})

    refute RpmsRpc::Procedure.add(nil, VISIT_IEN, CPT)[:success]
    refute RpmsRpc::Procedure.add(DFN, nil, CPT)[:success]
    refute RpmsRpc::Procedure.add(DFN, VISIT_IEN, "")[:success]
    assert_empty client.calls
  end

  def test_nil_or_non_positive_quantity_returns_failure_without_a_call
    client = replay({})

    refute RpmsRpc::Procedure.add(DFN, VISIT_IEN, CPT, quantity: nil)[:success]
    refute RpmsRpc::Procedure.add(DFN, VISIT_IEN, CPT, quantity: 0)[:success]
    refute RpmsRpc::Procedure.add(DFN, VISIT_IEN, CPT, quantity: -1)[:success]
    assert_empty client.calls
  end
end

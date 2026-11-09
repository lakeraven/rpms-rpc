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
# Procedure.add files through BEHOENPC SAVE (rpms-rpc#524). Its
# conversations are the build's (procedure-add.yml): the visit read, the
# V CPT rows before, the save, and the rows after, recorded as flows as
# PROFILE,MD on a throwaway container. test/live/procedure_add_live_test.rb
# proves the write against the V CPT file.
class ProcedureTest < Minitest::Test
  SLUG = "bgovcpt"
  ADD = "procedure-add"
  DFN       = "4"
  VISIT_IEN = "4"
  CPT       = "A0021"

  def teardown
    RpmsRpc.reset!
  end

  def replay(script)
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def capture(name) = CapturedReplies.raw(SLUG, name)
  def replay_flow(name) = replay(CapturedReplies.flow_script(ADD, name))
  def sent(client) = client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

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

  # --- add: BEHOENPC SAVE ----------------------------------------------------

  def test_add_files_the_cpt_on_the_visit_and_returns_its_ien
    client = replay_flow("add")

    result = RpmsRpc::Procedure.add(990_054, "117", CPT, quantity: 2)

    assert_equal({ success: true, ien: 11, raw: "0" }, result)
    assert_equal CapturedReplies.flow_calls(ADD, "add"), sent(client)
    assert_equal [ "DDR GETS ENTRY DATA", "BGOVCPT GET", "BEHOENPC SAVE", "BGOVCPT GET" ], sent(client).map(&:first)
  end

  def test_add_sends_the_visit_as_hdr_the_patient_and_one_cpt_line
    client = replay_flow("add")

    RpmsRpc::Procedure.add(990_054, "117", CPT, quantity: 2)

    save = client.calls.find { |c| c[:rpc] == "BEHOENPC SAVE" }
    assert_equal [ { 1 => "HDR^0^^6;3261109.1821;A;117", 2 => "VST^PT^990054", 3 => "CPT+^A0021^^^^^2" }, "0", "6" ],
                 save[:params], "HDR location;date;category;visit, VST^PT, CPT+ with quantity in piece 7 (BEHOENPC.m)"
  end

  def test_add_of_a_cpt_the_build_cannot_resolve_is_not_filed
    # SAVE answers 0 and files nothing (CPT^BEHOENPC: D:CODE>0 ...STORE);
    # the rows after are the rows before.
    replay_flow("add_unresolved_cpt")

    result = RpmsRpc::Procedure.add(990_054, "117", "NOTACPT")

    assert_equal({ success: false, ien: nil, raw: "0", error: :not_filed }, result)
  end

  def test_add_on_another_patients_visit_sends_no_write
    client = replay_flow("add_wrong_patient")

    result = RpmsRpc::Procedure.add(990_055, "117", CPT)

    assert_equal({ success: false, ien: nil, raw: nil, error: :wrong_patient }, result)
    assert_equal [ "DDR GETS ENTRY DATA" ], sent(client).map(&:first)
  end

  def test_add_on_a_visit_not_on_file_sends_no_write
    client = replay_flow("add_visit_not_found")

    result = RpmsRpc::Procedure.add(990_054, "999999", CPT)

    assert_equal({ success: false, ien: nil, raw: nil, error: :not_found }, result)
    assert_equal [ "DDR GETS ENTRY DATA" ], sent(client).map(&:first)
  end

  def test_add_on_a_visit_the_build_no_longer_lets_change_is_its_refusal
    client = replay_flow("add_locked_visit")

    result = RpmsRpc::Procedure.add(DFN, VISIT_IEN, CPT)

    assert_equal({ success: false, ien: nil, raw: "-1^The data associated with this visit may no longer be modified." }, result)
    assert_equal CapturedReplies.flow_calls(ADD, "add_locked_visit"), sent(client), "a refusal is not read back"
  end

  def test_add_whose_new_row_is_on_another_visit_is_not_filed
    # The add flow's replies, sent as if the visit were 118: the new row the
    # build lists is on visit 117, so it is not this call's.
    flow = CapturedReplies.flow_script(ADD, "add")
    replay(flow)

    result = RpmsRpc::Procedure.add(990_054, "118", CPT, quantity: 2)

    refute result[:success]
    assert_equal :not_filed, result[:error]
  end

  def test_add_whose_only_matching_row_was_there_before_is_not_filed
    # The add flow, with the rows after it as the rows before too: the A0021
    # row on visit 117 is an earlier one, not this call's.
    after = CapturedReplies.raw(ADD, "add/4")
    replay("DDR GETS ENTRY DATA" => [ CapturedReplies.raw(ADD, "add/1") ], "BGOVCPT GET" => [ after, after ],
           "BEHOENPC SAVE" => [ CapturedReplies.raw(ADD, "add/3") ])

    result = RpmsRpc::Procedure.add(990_054, "117", CPT, quantity: 2)

    assert_equal :not_filed, result[:error]
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

  def test_modifiers_or_a_narrative_raise_rather_than_drop
    client = replay({})

    assert_raises(ArgumentError) { RpmsRpc::Procedure.add(DFN, VISIT_IEN, CPT, modifiers: [ "25" ]) }
    assert_raises(ArgumentError) { RpmsRpc::Procedure.add(DFN, VISIT_IEN, CPT, narrative: "office visit") }
    assert_empty client.calls, "the CPT line files neither (CPT^BEHOENPC), so nothing is sent"
  end
end

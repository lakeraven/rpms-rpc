# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/eligibility"
require "rpms_rpc/api/coverage"
require "rpms_rpc/api/agg"
require_relative "../captured_replies"

# RpmsRpc::Coverage: insurance eligibility (Medicare/Medicaid/private) through
# AGG/BQI RPCs (rpms-rpc#382). Distinct from RpmsRpc::Eligibility (VFC immunization).
#
# The replies are the build's (test/fixtures/captured_replies/coverage.yml): each
# Coverage call run on a throwaway container as PROFILE,REG on demo patient
# 990048, recorded as a flow (with the guard reads each delete makes first) and
# replayed through CiaClient. The BQI reads were taken as the operator: the
# build answers BQI PATIENT INSURANCE to no clinical persona.
#
# Not captured, so not tested here: an eligibility row the build refuses, and so
# the add_medicare / add_medicaid failure and rollback paths (the build accepted
# every eligibility row it was sent, even an end before the start), a header
# reply with no record IEN, a billed-eligibility warning on delete, and the
# reply shapes of other transports. Those were tested against replies written
# by hand, which ADR 0009 retires. The round trip is test/live/coverage_write_live_test.rb.
class CoverageTest < Minitest::Test
  SLUG = "coverage"
  Cov = RpmsRpc::Coverage
  Agg = RpmsRpc::Agg
  FS = "\x1c" # $C(28): PARMS delimiter (AGGUPMCR.m:59, AGGUPMCD.m:132)

  MEDICARE_RPC = "AGG UPDATE MEDICARE"   # UPD^AGGUPMCR.m:7
  MEDICAID_RPC = "AGG UPDATE MEDICAID"   # UPD^AGGUPMCD.m:5
  BQI_RPC = "BQI PATIENT INSURANCE"      # GET^BQIPTINS.m:6
  CMS_EXAMPLE_MBI = "1EG4TE5MK73"

  DFN = 990_048
  OTHER_DFN = 990_049
  MEDICARE_ARGS = { roi_on: "11/01/2026", name: "ZZCOV,MEDICARE", number: CMS_EXAMPLE_MBI, suffix: "A",
                    effective_on: "11/01/2026" }.freeze

  def teardown
    RpmsRpc.reset!
  end

  def replay(script = {})
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def replay_flow(name) = replay(CapturedReplies.flow_script(SLUG, name))

  # The RPCs the gem sent, with the context bound when each went out.
  def wire(client)
    context = CapturedReplies::ReplayCiaClient::SIGNON_CONTEXT
    client.calls.filter_map do |c|
      next (context = c[:params].first) && nil if c[:rpc] == :create_context

      [ c[:rpc], c[:params], context ]
    end
  end

  def agg_calls(client, rpc) = wire(client).select { |r, _, _| r == rpc }

  # -- distinct from VFC Eligibility -----------------------------------------

  def test_module_is_not_vfc_eligibility
    refute_equal RpmsRpc::Eligibility, Cov
    assert_equal "RpmsRpc::Coverage", Cov.name
  end

  # -- for_patient (BQI PATIENT INSURANCE) -------------------------------------

  def test_for_patient_is_empty_when_nothing_is_on_file
    replay_flow("bqi_none")

    assert_equal({ entries: [] }, Cov.for_patient(DFN))
  end

  def test_for_patient_reads_medicare_and_medicaid_rows
    replay_flow("bqi_both")

    assert_equal({ entries: [ { coverage: "MEDICARE", effective_on: "NOV 1, 2026" },
                              { coverage: "MEDICAID FULL", effective_on: "NOV 1, 2026" } ] },
                 Cov.for_patient(DFN))
  end

  def test_for_patient_binds_bqirpc_and_restores_caller_context
    client = replay_flow("bqi_none")
    client.create_context("AGGRPC")

    Cov.for_patient(DFN)

    assert_equal [ [ BQI_RPC, [ DFN.to_s ], "BQIRPC" ] ], wire(client)
    assert_equal "AGGRPC", client.current_context
  end

  def test_for_patient_invalid_dfn_makes_no_rpc_call
    client = replay
    [ nil, "", "0", "-1", "abc", "3.5" ].each { |bad| assert_nil Cov.for_patient(bad) }
    assert_empty client.calls
  end

  # -- public API (rpms-rpc#382) ---------------------------------------------

  PUBLIC_METHODS = %i[
    for_patient add_medicare delete_medicare delete_medicare_record add_medicaid delete_medicaid
  ].freeze

  def test_public_coverage_api_surface
    PUBLIC_METHODS.each { |name| assert_respond_to Cov, name, "rpms-rpc#382" }
    refute_respond_to Cov, :medicare_update
    refute_respond_to Cov, :medicaid_update
  end

  def test_low_level_medicare_and_medicaid_writers_are_not_callable
    assert_raises(NoMethodError) { Cov.medicare_update(DFN, proc: "A", definition: Cov::MEDICARE_WINDOW) }
    assert_raises(NoMethodError) { Cov.medicaid_update(DFN, proc: "A", definition: Cov::MEDICAID_WINDOW) }
  end

  # Asserts on the real Coverage::WINDOW_FIELDS, so a RIEN/MIEN entry added to
  # the lib allowlist turns this red.
  def test_real_window_fields_exclude_rien_and_mien_and_cover_sent_names
    windows = Cov::MEDICARE_WINDOWS + Cov::MEDICAID_WINDOWS
    assert_equal windows.sort, Cov::WINDOW_FIELDS.keys.sort

    Cov::WINDOW_FIELDS.each do |window, names|
      refute_empty names, "#{window} allowlist must not be empty"
      assert_equal names.uniq, names, "#{window} allowlist has duplicates"
      names.each do |name|
        refute_includes %w[RIEN MIEN], name.upcase, "#{window}: IEN keys must not be PARMS allowlist entries"
        assert_match(/\A[A-Z]+\z/, name, "#{window}: #{name} is not a bare PARMS name")
      end
    end

    assert_empty %w[AGGMCROI AGGMCNME AGGMCNUM AGGMCSUF] - Cov::WINDOW_FIELDS[Cov::MEDICARE_WINDOW]
    assert_empty %w[AGGMCESD AGGMCCOV] - Cov::WINDOW_FIELDS[Cov::MEDICARE_ELIGIBILITY_WINDOW]
    assert_empty %w[AGGMDESD AGGMDECV] - Cov::WINDOW_FIELDS[Cov::MEDICAID_ELIGIBILITY_WINDOW]
  end

  # -- add_medicare (UPD^AGGUPMCR.m:7): header, then the eligibility row --------

  def test_add_medicare_files_header_then_eligibility_under_aggrpc
    client = replay_flow("add_medicare")

    result = Cov.add_medicare(DFN, **MEDICARE_ARGS)

    assert_equal({ success: true, error: nil, message: "", rien: DFN, mien: "1" }, result)
    assert_equal [
      [ MEDICARE_RPC, [ DFN.to_s, "A", Cov::MEDICARE_WINDOW, "",
                        "AGGMCROI=11/01/2026#{FS}AGGMCNME=ZZCOV,MEDICARE#{FS}AGGMCNUM=#{CMS_EXAMPLE_MBI}#{FS}AGGMCSUF=A" ], Agg::CONTEXT ],
      [ MEDICARE_RPC, [ DFN.to_s, "A", Cov::MEDICARE_ELIGIBILITY_WINDOW, "", "AGGMCESD=11/01/2026" ], Agg::CONTEXT ]
    ], wire(client)
    assert_equal CapturedReplies::ReplayCiaClient::SIGNON_CONTEXT, client.current_context
  end

  # "@" alone is FileMan's delete sentinel; a value that only contains it is data.
  def test_a_value_containing_at_is_sent
    client = replay_flow("add_medicare")

    Cov.add_medicare(DFN, **MEDICARE_ARGS, number: "AB@12")

    assert_includes agg_calls(client, MEDICARE_RPC).first[1].last, "AGGMCNUM=AB@12"
  end

  def test_add_medicare_restores_context_when_a_call_raises
    client = replay
    client.create_context("AGGRPC2")

    assert_raises(RuntimeError) { Cov.add_medicare(DFN, **MEDICARE_ARGS) }
    assert_equal "AGGRPC2", client.current_context
  end

  # -- add_medicaid (UPD^AGGUPMCD.m:5): record, then its eligibility row --------

  # The build keys the eligibility row by its start date (3261101).
  def test_add_medicaid_creates_record_then_eligibility_row
    client = replay_flow("add_medicaid")

    result = Cov.add_medicaid(DFN, effective_on: "11/01/2026", coverage: "FULL")

    assert_equal({ success: true, error: nil, message: "", record_ien: "3", multiple_ien: "3261101" }, result)
    assert_equal [ Cov::MEDICAID_WINDOW, Cov::MEDICAID_ELIGIBILITY_WINDOW ], agg_calls(client, MEDICAID_RPC).map { |_, p, _| p[2] }
    assert_equal [ DFN.to_s, "A", Cov::MEDICAID_ELIGIBILITY_WINDOW, "3", "", "AGGMDESD=11/01/2026#{FS}AGGMDECV=FULL" ],
                 agg_calls(client, MEDICAID_RPC).last[1]
  end

  # -- reads of what is on file ------------------------------------------------

  def test_on_file_reads_medicare_and_medicaid_with_their_eligibility
    replay_flow("on_file_both")

    found = Cov.on_file(DFN)

    medicaid = found[:medicaid].first
    assert_equal [ "3", true ], [ medicaid[:record_ien], medicaid[:active] ]
    assert_equal [ { ien: "3261101", starts_on: Date.new(2026, 11, 1), ends_on: nil, coverage: "FULL" } ], medicaid[:eligibility]
    medicare = found[:medicare].first
    assert_equal [ "990048", CMS_EXAMPLE_MBI, true ], [ medicare[:record_ien], medicare[:number], medicare[:active] ]
    assert_equal [ "1", Date.new(2026, 11, 1) ], medicare[:eligibility].first.values_at(:ien, :starts_on)
    assert_equal [], found[:private]
  end

  def test_insurers_reads_the_builds_insurer_list
    replay_flow("insurers")

    assert_equal({ ien: "1", name: "RAILROAD RETIREMENT", city: "", state: "TEXAS", status: "BILLABLE", type: "MEDICARE FI" },
                 Cov.insurers.first)
  end

  # -- deletes: the guard reads come first ------------------------------------

  def test_delete_medicare_record_refuses_while_an_eligibility_row_remains
    client = replay_flow("delete_medicare_record_with_rows")

    result = Cov.delete_medicare_record(DFN)

    assert_equal :verification_failed, result[:error]
    assert_empty agg_calls(client, MEDICARE_RPC), "no delete while a row remains"
  end

  def test_delete_medicaid_refuses_a_record_that_is_not_the_patients
    client = replay_flow("delete_medicaid_other_patient")

    result = Cov.delete_medicaid(OTHER_DFN, record_ien: "3", eligibility_mien: "3261101")

    assert_equal :verification_failed, result[:error]
    assert_empty agg_calls(client, MEDICAID_RPC)
  end

  def test_delete_medicare_sends_one_eligibility_row_delete
    client = replay_flow("delete_medicare")

    result = Cov.delete_medicare(DFN, eligibility_mien: "1")

    assert result[:success]
    assert_equal [ [ MEDICARE_RPC, [ DFN.to_s, "D", Cov::MEDICARE_ELIGIBILITY_WINDOW, "1", "" ], Agg::CONTEXT ] ],
                 agg_calls(client, MEDICARE_RPC)
  end

  # The guard reads go to the client passed in, not to RpmsRpc.client.
  def test_delete_guard_reads_use_the_passed_client
    default = replay
    write = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script(SLUG, "delete_medicare"))

    assert Cov.delete_medicare(DFN, eligibility_mien: "1", client: write)[:success]
    assert_empty default.calls
    assert_equal [ "DDR GETS ENTRY DATA", MEDICARE_RPC ], write.rpcs_called.grep(String)
  end

  def test_delete_medicaid_sends_one_eligibility_row_delete
    client = replay_flow("delete_medicaid")

    result = Cov.delete_medicaid(DFN, record_ien: "3", eligibility_mien: "3261101")

    assert_equal({ success: true, error: nil, message: "", record_ien: "3", multiple_ien: "3261101" }, result)
    assert_equal [ [ MEDICAID_RPC, [ DFN.to_s, "D", Cov::MEDICAID_ELIGIBILITY_WINDOW, "3", "3261101", "" ], Agg::CONTEXT ] ],
                 agg_calls(client, MEDICAID_RPC)
  end

  def test_delete_medicare_record_deletes_the_header_once_no_row_remains
    client = replay_flow("delete_medicare_record")

    assert Cov.delete_medicare_record(DFN)[:success]
    assert_equal [ [ MEDICARE_RPC, [ DFN.to_s, "D", Cov::MEDICARE_WINDOW, "", "" ], Agg::CONTEXT ] ],
                 agg_calls(client, MEDICARE_RPC)
  end

  def test_delete_medicare_without_a_header_is_no_medicare
    client = replay_flow("delete_medicare_none")

    assert_equal :no_medicare, Cov.delete_medicare(DFN, eligibility_mien: "1")[:error]
    assert_empty agg_calls(client, MEDICARE_RPC)
  end

  # -- guards: refused before the wire ----------------------------------------

  def test_add_medicare_refuses_bad_field_values_before_wire
    [ { name: "BAD^NAME" }, { number: "MBI=1" }, { name: "ZZ\x1fCOV" }, { roi_on: "13/01/2026" },
      { effective_on: nil }, { name: "@" }, { number: "@" }, { suffix: "@" }, { number: "  @  " } ].each do |override|
      client = replay
      assert_raises(ArgumentError, "#{override.inspect} must be refused") { Cov.add_medicare(DFN, **MEDICARE_ARGS, **override) }
      assert_empty client.calls, "#{override.inspect} reached the wire"
    end
  end

  def test_add_medicaid_refuses_bad_coverage_or_dates_before_wire
    [ { coverage: "OVERRIDE=Y" }, { coverage: "full override" }, { coverage: "FULL=Y" }, { coverage: "@" },
      { effective_on: nil } ].each do |override|
      client = replay
      args = { effective_on: "11/01/2026", coverage: "FULL" }.merge(override)
      assert_raises(ArgumentError, "#{override.inspect} must be refused") { Cov.add_medicaid(DFN, **args) }
      assert_empty client.calls, "#{override.inspect} reached the wire"
    end
  end

  def test_deletes_refuse_bad_iens_before_wire
    client = replay
    [ "", "0", "-1", "1.5", "abc" ].each do |bad|
      assert_raises(ArgumentError) { Cov.delete_medicare(DFN, eligibility_mien: bad) }
    end
    [ [ "", "1" ], [ "0", "1" ], [ "9", "" ], [ "9", "0" ], [ "9", "-2" ], [ "9", "x" ] ].each do |record, mult|
      assert_raises(ArgumentError) { Cov.delete_medicaid(DFN, record_ien: record, eligibility_mien: mult) }
    end
    assert_empty client.calls
  end
end

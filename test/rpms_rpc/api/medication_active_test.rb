# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/medication"
require_relative "../captured_replies"

# ORWPS ACTIVE (ACTIVE^ORWPS, ORWPS.m:17-51) returns one ~TYPE^FIELDS header per
# medication, then instruction lines and t-prefixed comment/reason lines until
# the next ~. These tests read the reply a fresh rpms-ydb container sent
# (test/fixtures/captured_replies/orwps-active.yml), replayed through CiaClient.
#
# No demo patient on the build has a medication (pharmacy is out of scope), so
# no capture holds a ~ header, and the parse of OP, UD, IV and NV rows is not
# proven here. The tests that read those rows answered with replies written by
# hand, which ADR 0009 retires; a capture with a medication row brings them back.
class MedicationActiveTest < Minitest::Test
  ACTIVE = "ORWPS ACTIVE"

  def teardown
    RpmsRpc.reset!
  end

  def replay(script)
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  # ACTIVE(LST,DFN) (ORWPS.m:17): the broker frame is DFN only; LST is the return array.
  def test_active_for_patient_dispatches_orwps_active_with_dfn_only
    client = replay(ACTIVE => [ CapturedReplies.raw("orwps-active", "dfn_4") ])

    RpmsRpc::Medication.active_for_patient("4")

    assert_equal [ { rpc: ACTIVE, params: [ "4" ] } ], client.calls
  end

  def test_active_for_patient_with_no_medication_is_empty
    replay(ACTIVE => [ CapturedReplies.raw("orwps-active", "dfn_4") ])

    assert_equal [], RpmsRpc::Medication.active_for_patient("4")
  end

  def test_active_for_patient_invalid_dfn_returns_empty_without_dispatch
    client = replay({})

    [ nil, "", "   ", 0, -1 ].each { |dfn| assert_equal [], RpmsRpc::Medication.active_for_patient(dfn) }
    assert_empty client.calls
  end

  # The ORQQPS LIST path stays on the condensed list RPC (#422 does not replace it).
  def test_medication_for_patient_still_dispatches_orqqps_list
    client = replay("ORQQPS LIST" => [ CapturedReplies.raw("clinical-data", "medications_none") ])

    RpmsRpc::Medication.for_patient("4")

    assert_equal [ { rpc: "ORQQPS LIST", params: [ "4", "", "" ] } ], client.calls
  end
end

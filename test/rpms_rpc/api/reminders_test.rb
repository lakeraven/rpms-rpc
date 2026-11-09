# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/reminders"
require_relative "../captured_replies"

# RpmsRpc::Reminders reads what RPMS's own reminder evaluation returns:
# ORQQPXRM REMINDERS APPLICABLE -> APPL^ORQQPXRM (ORQQPXRM.m:10-11) ->
# EVALCOVR^ORQQPX (ORQQPX.m:232-236) -> AVAL^PXRMRPCA (PXRMRPCA.m:49-82).
# The replies are the pinned build's evaluation of two seed patients
# (test/fixtures/captured_replies/orqqpxrm-reminders-applicable.yml),
# replayed through CiaClient (#238).
#
# Row layout: IEN^PRINT NAME^DUE DATE^LAST DONE^PRIORITY^DUE FLAG^DIALOG^^^^
# DIALOG WIPE (PXRMRPCA.m:76 for applicable rows, :80 for not-applicable).
# The build's evaluation sends due flags 0, 1, 2 and 4; no seed patient
# evaluates to 3 (error), so that status has no captured row here.
class RemindersTest < Minitest::Test
  SLUG = "orqqpxrm-reminders-applicable"
  RPC = "ORQQPXRM REMINDERS APPLICABLE"

  def teardown
    RpmsRpc.reset!
  end

  def replay(*names)
    client = CapturedReplies::ReplayCiaClient.new(RPC => names.map { |n| CapturedReplies.raw(SLUG, n) })
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def rows(dfn = "4", location = nil) = RpmsRpc::Reminders.applicable(dfn, location)

  def test_sends_the_dfn_and_the_location
    client = replay("dfn_4_at_location")

    refute_empty rows("4", "6")
    assert_equal [ { rpc: RPC, params: [ "4", "6" ] } ], client.calls
  end

  def test_location_is_optional_and_sent_empty
    client = replay("dfn_4")

    rows
    assert_equal [ "4", "" ], client.calls.first[:params]
  end

  def test_never_reads_the_triage_summary
    client = replay("dfn_4")

    rows
    assert_equal [ RPC ], client.rpcs_called
  end

  def test_an_applicable_row_carries_the_aval_fields
    replay("dfn_4")

    depression = rows.find { |r| r[:id] == 123 }

    assert_equal({ id: 123, name: "Depression Screen", status: :applicable, due_flag: 0,
                   due_date: Date.new(2027, 9, 2), due_now: false, last_done: Date.new(2026, 9, 2),
                   priority: 2, has_dialog: true }, depression)
  end

  def test_due_flag_maps_to_the_aval_status_codes
    # PXRMRPCA.m:56-67: 2 is the default (not applicable), 0 applicable,
    # 1 due, 4 cannot be determined.
    replay("dfn_4", "dfn_3")

    assert_equal %i[cannot_be_determined cannot_be_determined applicable due due], rows.map { |r| r[:status] }
    assert_equal %i[cannot_be_determined not_applicable not_applicable not_applicable not_applicable],
                 rows("3").map { |r| r[:status] }
  end

  def test_due_now_sentinel_is_kept_and_not_read_as_a_date
    # PXRMDATE.m:132: no resolution date -> DUEDATE is the text "DUE NOW".
    replay("dfn_4")

    tobacco = rows.find { |r| r[:id] == 211 }

    assert_equal :due, tobacco[:status]
    assert_equal true, tobacco[:due_now]
    assert_nil tobacco[:due_date]
    assert_nil tobacco[:last_done]
  end

  def test_cnbd_due_date_sentinel_is_not_a_date
    # PXRMDATE.m:129: no frequency -> DUEDATE is the text "CNBD".
    replay("dfn_4")

    weight = rows.find { |r| r[:id] == 212 }

    assert_equal :cannot_be_determined, weight[:status]
    assert_nil weight[:due_date]
    assert_equal false, weight[:due_now]
  end

  def test_not_applicable_rows_are_returned_as_rpms_returns_them
    # PXRMRPCA.m:78-80: N/A rows carry no dates and no priority.
    replay("dfn_3")

    mammogram = rows("3").find { |r| r[:id] == 309 }

    assert_equal :not_applicable, mammogram[:status]
    assert_nil mammogram[:priority]
    assert_nil mammogram[:due_date]
    assert_nil mammogram[:last_done]
  end

  def test_returns_empty_for_blank_or_non_positive_dfn_without_calling
    client = replay

    assert_equal [], RpmsRpc::Reminders.applicable(nil, "6")
    assert_equal [], RpmsRpc::Reminders.applicable("", "6")
    assert_equal [], RpmsRpc::Reminders.applicable("0", "6")
    assert_empty client.calls
  end

  def test_returns_empty_when_nothing_evaluates
    replay("no_such_patient")

    assert_equal [], rows("999999")
  end

  def test_visit_keyed_read_is_gone
    refute_respond_to RpmsRpc::Reminders, :for_visit,
                      "RPMS has no visit-keyed reminder method (ADR 0008 section 3)"
  end
end

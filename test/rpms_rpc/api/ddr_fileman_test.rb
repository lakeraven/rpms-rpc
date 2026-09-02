# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/ddr_fileman"

# Tests for RpmsRpc::DdrFileman — the FileMan Delphi Components RPC family
# (DDR*, LISTC^DDR / LOCKC^DDR1 / GETSC^DDR2 / FILEC^DDR3 / VALC^DDR3) plus
# request-builder / reply-parser coverage. Wire shapes cited from the
# bcer-9.0-ydb corpus in each production mapping/builder; the tests below
# pin the exact params each RPC receives and the reply grammars.
class DdrFilemanTest < Minitest::Test
  Ddr = RpmsRpc::DdrFileman

  def setup
    @mock = RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  # ==========================================================================
  # Request builders (exact param order/encoding)
  # ==========================================================================

  def test_filer_params_build_mode_root_flags_iens
    params = Ddr.filer_params(
      mode: "ADD",
      rows: [
        { file: "9000001", field: ".01", iens: "+1,", value: "42" },
        { file: "9000001.41", field: ".02", iens: "+2,+1,", value: "100001" }
      ],
      iens: { 1 => 42, 2 => 5 }
    )

    assert_equal 4, params.length
    assert_equal "ADD", params[0]
    # DDRROOT(n) = "FILE^FIELD^IENS^VALUE" (FDASET^DDR3: DDR3.m:29-34)
    assert_equal({ 1 => "9000001^.01^+1,^42", 2 => "9000001.41^.02^+2,+1,^100001" }, params[1])
    assert_equal "", params[2]
    # DDRIENS(n) = pinned IEN for placeholder n (FILEC^DDR3: DDR3.m:12-13)
    assert_equal({ 1 => "42", 2 => "5" }, params[3])
  end

  def test_lister_param_orders_keys_like_parse_ddr_and_omits_nils
    param = Ddr.lister_param(file: "9000001", xref: "D", part: "100001", max: "*")

    # Key order mirrors PARSE^DDR's read order (DDR.m:53-65); nil criteria
    # are omitted entirely (server $G-defaults them).
    assert_equal [ "FILE", "MAX", "PART", "XREF" ], param.keys
    assert_equal({ "FILE" => "9000001", "MAX" => "*", "PART" => "100001", "XREF" => "D" }, param)
  end

  def test_lock_param_sets_node_lockmode_timeout
    param = Ddr.lock_param(node: "^AUPNPAT(42)", timeout: 7)

    # LOCKC^DDR1 reads NODE / LOCKMODE / TIMEOUT (DDR1.m:18-27)
    assert_equal({ "NODE" => "^AUPNPAT(42)", "LOCKMODE" => "1", "TIMEOUT" => "7" }, param)
  end

  def test_unlock_param_omits_lockmode
    # Unlock branch = LOCKMODE absent/false (DDR1.m:25-27)
    assert_equal({ "NODE" => "^AUPNPAT(42)" }, Ddr.unlock_param(node: "^AUPNPAT(42)"))
  end

  def test_gets_entry_param_builds_file_iens_fields_flags
    param = Ddr.gets_entry_param(file: "9000001", iens: "42,", fields: ".01", flags: "IE")

    # GETSC^DDR2 reads FILE / IENS / FIELDS / FLAGS (PARSE^DDR2: DDR2.m:113-121)
    assert_equal({ "FILE" => "9000001", "IENS" => "42,", "FIELDS" => ".01", "FLAGS" => "IE" }, param)
  end

  def test_validator_param_builds_file_iens_field_value
    param = Ddr.validator_param(file: "9000001.41", iens: "+2,42,", field: ".02", value: "100001")

    # VALC^DDR3 reads FILE / IENS / FIELD / VALUE (DDR3.m:37-44)
    assert_equal(
      { "FILE" => "9000001.41", "IENS" => "+2,42,", "FIELD" => ".02", "VALUE" => "100001" },
      param
    )
  end

  # ==========================================================================
  # DDR FILER — filer() call + reply parsing
  # ==========================================================================

  ROWS = [ { file: "9000001", field: ".01", iens: "+1,", value: "42" } ].freeze

  def test_filer_success_returns_resolved_iens
    @mock.seed(:ddr_filer, "ADD", "[Data]\n+1,^42")

    result = Ddr.filer(mode: "ADD", rows: ROWS, iens: { 1 => 42 })

    assert result[:success]
    # "+"_I_","_U_DDRRTN(I) rows (DDR3.m:20-22)
    assert_equal({ 1 => "42" }, result[:iens])
    call = @mock.received_calls.last
    assert_equal "DDR FILER", call[:rpc]
    assert_equal [ "ADD", { 1 => "9000001^.01^+1,^42" }, "", { 1 => "42" } ], call[:params]
  end

  def test_filer_error_block_surfaces_fileman_text
    @mock.seed(:ddr_filer, "ADD",
      "[Data]\n[BEGIN_diERRORS]\n701^1^9000001^+1,^.01^2\nFILE^9000001\nIENS^+1,\nThe value is not valid.\n[END_diERRORS]")

    result = Ddr.filer(mode: "ADD", rows: ROWS)

    refute result[:success]
    # Message lines are the plain-text DIERR TEXT nodes inside the
    # [BEGIN_diERRORS] block (ERROR^DDR3: DDR3.m:63-79)
    assert_includes result[:errors].join, "The value is not valid."
  end

  def test_filer_returns_nil_when_broker_gives_no_response
    assert_nil Ddr.filer(mode: "ADD", rows: ROWS)
  end

  # ==========================================================================
  # DDR LISTER — lister() call + V0 reply parsing
  # ==========================================================================

  def test_lister_parses_data_rows_ien_first
    key = Ddr.lister_param(file: "9000001", xref: "D", part: "100001", max: "*").to_s
    @mock.seed(:ddr_lister, key, "[Data]\n43^100001\n44^100001A")

    result = Ddr.lister(file: "9000001", xref: "D", part: "100001", max: "*")

    refute result[:error]
    assert_equal 2, result[:entries].length
    assert_equal "43", result[:entries][0][:ien]
    assert_equal [ "100001" ], result[:entries][0][:pieces]
  end

  def test_lister_parses_misc_more_marker
    key = Ddr.lister_param(file: "9000001", xref: "B").to_s
    @mock.seed(:ddr_lister, key, "[Misc]\nMORE^DEMOPATIENT,UNA^43\n[Data]\n42^DEMOPATIENT,ALPHA")

    result = Ddr.lister(file: "9000001", xref: "B")

    # "MORE"^from^from("IEN") continuation marker (V0^DDR: DDR.m:24,45)
    assert_equal({ value: "DEMOPATIENT,UNA", ien: "43" }, result[:more])
    assert_equal 1, result[:entries].length
  end

  def test_lister_flags_error_marker
    key = Ddr.lister_param(file: "9000001").to_s
    @mock.seed(:ddr_lister, key, "[Data]\n[Errors]")

    result = Ddr.lister(file: "9000001")

    assert result[:error]
    assert_empty result[:entries]
  end

  def test_lister_returns_nil_when_broker_gives_no_response
    assert_nil Ddr.lister(file: "9000001", xref: "D", part: "999999")
  end

  # ==========================================================================
  # DDR LOCK/UNLOCK NODE
  # ==========================================================================

  def test_lock_true_on_1
    @mock.seed(:ddr_lock_unlock_node, Ddr.lock_param(node: "^AUPNPAT(42)").to_s, true)

    assert Ddr.lock(node: "^AUPNPAT(42)")
  end

  def test_lock_false_on_0
    @mock.seed(:ddr_lock_unlock_node, Ddr.lock_param(node: "^AUPNPAT(42)").to_s, false)

    refute Ddr.lock(node: "^AUPNPAT(42)")
  end

  def test_lock_false_when_broker_gives_no_response
    refute Ddr.lock(node: "^AUPNPAT(42)")
  end

  def test_unlock_sends_unlock_param
    @mock.seed(:ddr_lock_unlock_node, Ddr.unlock_param(node: "^AUPNPAT(42)").to_s, true)

    assert Ddr.unlock(node: "^AUPNPAT(42)")
    assert_equal [ { "NODE" => "^AUPNPAT(42)" } ], @mock.received_calls.last[:params]
  end

  # ==========================================================================
  # DDR GETS ENTRY DATA — default (no OPTIONS) reply format
  # ==========================================================================

  def test_gets_entry_parses_field_rows
    key = Ddr.gets_entry_param(file: "9000001", iens: "42,", fields: ".01", flags: "IE").to_s
    # Row = FILE^IENS-without-trailing-comma^FIELD^INTERNAL^EXTERNAL
    # (tag 1, GETSC^DDR2: DDR2.m:27-43)
    @mock.seed(:ddr_gets_entry_data, key, "[Data]\n9000001^42^.01^42^DEMOPATIENT,UNA")

    result = Ddr.gets_entry(file: "9000001", iens: "42,", fields: ".01", flags: "IE")

    refute result[:error]
    assert_equal({ internal: "42", external: "DEMOPATIENT,UNA" }, result[:fields][".01"])
  end

  def test_gets_entry_flags_error_marker
    key = Ddr.gets_entry_param(file: "9000001", iens: "99999,", fields: ".01").to_s
    # "[ERROR]" marker when DDRERR is set (tag 2, DDR2.m:61)
    @mock.seed(:ddr_gets_entry_data, key, "[ERROR]")

    result = Ddr.gets_entry(file: "9000001", iens: "99999,", fields: ".01")

    assert result[:error]
    assert_empty result[:fields]
  end

  def test_gets_entry_returns_nil_when_broker_gives_no_response
    assert_nil Ddr.gets_entry(file: "9000001", iens: "42,", fields: ".01")
  end

  # ==========================================================================
  # DDR VALIDATOR
  # ==========================================================================

  def test_validate_field_valid_value
    key = Ddr.validator_param(file: "9000001.41", iens: "+2,42,", field: ".02", value: "100001").to_s
    # Reply lines: [FILLER], [Data], DDRRSLT (internal; "^" = invalid),
    # DDRRSLT(0) (external) — VALC^DDR3: DDR3.m:44-49
    @mock.seed(:ddr_validator, key, "[FILLER]\n[Data]\n100001\n100001")

    result = Ddr.validate_field(file: "9000001.41", iens: "+2,42,", field: ".02", value: "100001")

    assert result[:valid]
    assert_equal "100001", result[:internal]
  end

  def test_validate_field_invalid_value_is_caret
    key = Ddr.validator_param(file: "9000001", iens: "42,", field: ".03", value: "BAD").to_s
    @mock.seed(:ddr_validator, key, "[FILLER]\n[Data]\n^\n")

    result = Ddr.validate_field(file: "9000001", iens: "42,", field: ".03", value: "BAD")

    refute result[:valid]
  end

  def test_validate_field_returns_nil_when_broker_gives_no_response
    assert_nil Ddr.validate_field(file: "9000001", iens: "42,", field: ".03", value: "X")
  end
end

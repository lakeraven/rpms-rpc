# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/problem"
require "rpms_rpc/retry_safety"

# Stock-VistA problem writes via ORQQPL ADD SAVE / ORQQPL EDIT SAVE (ORQQPL1.m).
# BGOPROB add/update/delete stay on the IHS path (rpms-rpc#457).
class ProblemStockWriteTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")

  DFN = "8791"
  IEN = "5001"
  PROVIDER = "301"
  VAMC = "7"

  STOCK_RESULT_KEYS = %i[success ien raw].freeze
  STOCK_REFUSAL = { success: false, ien: nil, raw: nil }.freeze

  def teardown
    RpmsRpc.reset!
  end

  # ADDSAVE(RETURN,GMPDFN,GMPROV,GMPVAMC,ADDARRAY) — stock adds GMPSRCH as a
  # sixth formal callers must not send; wire exactly four actuals (WorldVistA
  # ORQQPL1.m:191). Success RETURN=1 (ORQQPL1.m:228); lock failure RETURN=0
  # (ORQQPL1.m:201).
  def test_add_stock_dispatches_orqqpl_add_save_with_four_formals_and_gmpfld_list
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_add_save, DFN, "1")
    end

    result = RpmsRpc::Problem.add_stock(
      DFN,
      provider_duz: PROVIDER,
      vamc: VAMC,
      fields: { ".01" => "Hypertension", "1.01" => "I10" },
      comments: [ "follow-up" ]
    )

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORQQPL ADD SAVE" }
    refute_nil call
    assert_equal 4, call[:params].length, "ADDSAVE sends dfn, provider, vamc, list only (ORQQPL1.m:191)"
    assert_equal [ DFN, PROVIDER, VAMC ], call[:params].first(3)

    values = ordered_list_values(call[:params][3])
    assert_equal(
      [
        'GMPFLD(.01)="Hypertension"',
        'GMPFLD(1.01)="I10"',
        'GMPFLD(10,"NEW",1)="follow-up"'
      ],
      values
    )
    assert_equal (1..values.length).to_a, list_keys(call[:params][3])

    assert result[:success]
    refute_bgoprob_or_ddr_calls
  end

  # EDSAVE(RETURN,GMPIFN,GMPROV,GMPVAMC,UT,EDARRAY) — stock adds GMPSRCH;
  # wire five actuals: problem IEN, provider, vamc, UT, list (ORQQPL1.m:118).
  def test_update_stock_dispatches_orqqpl_edit_save_with_five_formals_gmpfld_and_gmporig
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_edit_save, IEN, "1")
    end

    result = RpmsRpc::Problem.update_stock(
      IEN,
      provider_duz: PROVIDER,
      vamc: VAMC,
      changes: { ".05" => "Updated narrative" },
      originals: { ".05" => "Old narrative" },
      user_type: true,
      comments: [ "edited in CPRS" ]
    )

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORQQPL EDIT SAVE" }
    refute_nil call
    assert_equal 5, call[:params].length, "EDSAVE sends ien, provider, vamc, UT, list (ORQQPL1.m:118)"
    assert_equal [ IEN, PROVIDER, VAMC, "1" ], call[:params].first(4)

    values = ordered_list_values(call[:params][4])
    assert_includes values, 'GMPFLD(.05)="Updated narrative"'
    assert_includes values, 'GMPORIG(.05)="Old narrative"'
    assert_includes values, 'GMPFLD(10,"NEW",1)="edited in CPRS"'

    RpmsRpc.reset!
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_edit_save, IEN, "1")
    end
    RpmsRpc::Problem.update_stock(
      IEN,
      provider_duz: PROVIDER,
      vamc: VAMC,
      changes: { 10 => "Chronic" },
      originals: { 10 => "Acute" },
      user_type: false
    )
    ut_call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORQQPL EDIT SAVE" }
    assert_equal "0", ut_call[:params][3], 'UT is "0" or "1" (ORQQPL1.m:118)'

    assert result[:success]
    refute_bgoprob_or_ddr_calls
  end

  def test_stock_write_doubles_embedded_quotes_and_never_emits_unbalanced_gmpfld_literals
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_add_save, DFN, "1")
    end

    quoted = 'say "hi"'
    injection = 'x" K ^AUPNPROB S Y="'

    RpmsRpc::Problem.add_stock(
      DFN,
      provider_duz: PROVIDER,
      vamc: VAMC,
      fields: { ".05" => quoted }
    )
    add_values = ordered_list_values(RpmsRpc.client.received_calls.last[:params][3])
    assert_equal [ 'GMPFLD(.05)="say ""hi"""' ], add_values
    assert_balanced_gmpfld_literal(add_values.first)

    RpmsRpc.reset!
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_add_save, DFN, "1")
    end

    RpmsRpc::Problem.add_stock(
      DFN,
      provider_duz: PROVIDER,
      vamc: VAMC,
      fields: { ".05" => injection }
    )
    inj_line = ordered_list_values(RpmsRpc.client.received_calls.last[:params][3]).first
    assert_equal 'GMPFLD(.05)="x"" K ^AUPNPROB S Y="""', inj_line
    assert_balanced_gmpfld_literal(inj_line)
  end

  def test_invalid_field_numbers_values_and_ids_are_refused_before_any_rpc
    refusal_cases = [
      -> { RpmsRpc::Problem.add_stock(nil, provider_duz: PROVIDER, vamc: VAMC, fields: { ".01" => "x" }) },
      -> { RpmsRpc::Problem.add_stock("0", provider_duz: PROVIDER, vamc: VAMC, fields: { ".01" => "x" }) },
      -> { RpmsRpc::Problem.add_stock(DFN, provider_duz: "0", vamc: VAMC, fields: { ".01" => "x" }) },
      -> { RpmsRpc::Problem.add_stock(DFN, provider_duz: PROVIDER, vamc: nil, fields: { ".01" => "x" }) },
      -> { RpmsRpc::Problem.add_stock(DFN, provider_duz: PROVIDER, vamc: VAMC, fields: {}) },
      -> { RpmsRpc::Problem.add_stock(DFN, provider_duz: PROVIDER, vamc: VAMC, fields: { ".01" => "ok", "" => "x" }) },
      -> { RpmsRpc::Problem.add_stock(DFN, provider_duz: PROVIDER, vamc: VAMC, fields: { nil => "x" }) },
      -> { RpmsRpc::Problem.add_stock(DFN, provider_duz: PROVIDER, vamc: VAMC, fields: { "abc" => "x" }) },
      -> { RpmsRpc::Problem.add_stock(DFN, provider_duz: PROVIDER, vamc: VAMC, fields: { "1..2" => "x" }) },
      -> { RpmsRpc::Problem.add_stock(DFN, provider_duz: PROVIDER, vamc: VAMC, fields: { ".01) K ^X S Y(1" => "x" }) },
      -> { RpmsRpc::Problem.add_stock(DFN, provider_duz: PROVIDER, vamc: VAMC, fields: { ".01" => "line\nbreak" }) },
      -> { RpmsRpc::Problem.add_stock(DFN, provider_duz: PROVIDER, vamc: VAMC, fields: { ".01" => "bad\x00byte" }) },
      -> { RpmsRpc::Problem.add_stock(DFN, provider_duz: PROVIDER, vamc: VAMC, fields: { ".01" => :symbol }) },
      -> {
        RpmsRpc::Problem.update_stock(
          nil, provider_duz: PROVIDER, vamc: VAMC,
          changes: { ".01" => "x" }, originals: { ".01" => "y" }
        )
      },
      -> {
        RpmsRpc::Problem.update_stock(
          IEN, provider_duz: PROVIDER, vamc: VAMC,
          changes: { "abc" => "x" }, originals: { ".01" => "y" }
        )
      }
    ]

    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_add_save, DFN, "1")
      m.seed_scalar(:problem_edit_save, IEN, "1")
    end

    refusal_cases.each do |invoke|
      RpmsRpc.client.received_calls.clear
      result = invoke.call
      assert_equal STOCK_REFUSAL, result
      assert_empty RpmsRpc.client.received_calls, "unsafe input must fail closed before ORQQPL (ORQQPL1.m:160,:120)"
    end
  end

  def test_add_stock_integer_field_values_are_coerced_to_strings_on_the_wire
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_add_save, DFN, "1")
    end

    RpmsRpc::Problem.add_stock(
      DFN,
      provider_duz: PROVIDER,
      vamc: VAMC,
      fields: { ".01" => 12345 }
    )

    values = ordered_list_values(RpmsRpc.client.received_calls.last[:params][3])
    assert_equal [ 'GMPFLD(.01)="12345"' ], values
  end

  def test_stock_save_replies_fail_closed_except_bare_one_success
    [
      [ :problem_add_save, DFN, :add_stock,
        -> {
          RpmsRpc::Problem.add_stock(DFN, provider_duz: PROVIDER, vamc: VAMC, fields: { ".01" => "x" })
        } ],
      [ :problem_edit_save, IEN, :update_stock,
        -> {
          RpmsRpc::Problem.update_stock(
            IEN, provider_duz: PROVIDER, vamc: VAMC,
            changes: { ".01" => "n" }, originals: { ".01" => "o" }
          )
        } ]
    ].each do |mapping, key, _method_name, invoke|
      RpmsRpc.mock! do |m|
        m.seed_scalar(mapping, key, "1")
      end
      result = invoke.call
      assert result[:success], "bare reply \"1\" is success (ORQQPL1.m:167,:128)"
      assert_stock_result_shape(result)
      if mapping == :problem_add_save
        assert_nil result[:ien], "ADDSAVE overwrites RETURN with 1; new IFN is not returned (ORQQPL1.m:164,:167)"
      else
        assert_equal IEN.to_i, result[:ien]
      end
      RpmsRpc.reset!
    end

    [
      [ :problem_add_save, DFN,
        -> {
          RpmsRpc::Problem.add_stock(DFN, provider_duz: PROVIDER, vamc: VAMC, fields: { ".01" => "x" })
        } ],
      [ :problem_edit_save, IEN,
        -> {
          RpmsRpc::Problem.update_stock(
            IEN, provider_duz: PROVIDER, vamc: VAMC,
            changes: { ".01" => "n" }, originals: { ".01" => "o" }
          )
        } ]
    ].each do |mapping, key, invoke|
      RpmsRpc.mock! do |m|
        m.seed_scalar(mapping, key, "0")
      end
      result = invoke.call
      refute result[:success]
      assert_stock_result_shape(result)
      assert_nil result[:ien]
      RpmsRpc.reset!
    end

    [ "", "2", "1^x" ].each do |reply|
      RpmsRpc.mock! do |m|
        m.seed_scalar(:problem_add_save, DFN, reply)
      end
      result = RpmsRpc::Problem.add_stock(
        DFN, provider_duz: PROVIDER, vamc: VAMC, fields: { ".01" => "x" }
      )
      refute result[:success], "reply #{reply.inspect} must never read as success"
      assert_stock_result_shape(result)
      assert_nil result[:ien]
      RpmsRpc.reset!
    end

    RpmsRpc.mock! do |m|
    end
    empty_result = RpmsRpc::Problem.add_stock(
      DFN, provider_duz: PROVIDER, vamc: VAMC, fields: { ".01" => "x" }
    )
    refute empty_result[:success], "empty broker reply must fail closed"
    assert_stock_result_shape(empty_result)
    assert_nil empty_result[:ien]
  end

  def test_stock_write_results_match_problem_write_and_failure_shape
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_set, DFN, "5001")
    end
    add_reference = RpmsRpc::Problem.add(
      DFN, { icd_code: "I10", description: "x", location_ien: "3049" }
    )
    assert_equal STOCK_RESULT_KEYS.sort, add_reference.keys.sort

    RpmsRpc.reset!
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_set, DFN, "5001")
    end
    update_reference = RpmsRpc::Problem.update(DFN, IEN, { description: "Updated" })
    assert_equal STOCK_RESULT_KEYS.sort, update_reference.keys.sort

    failure_reference = RpmsRpc::Problem.add(nil, { icd_code: "I10" })
    assert_equal STOCK_RESULT_KEYS.sort, failure_reference.keys.sort
    assert_equal STOCK_REFUSAL, failure_reference

    RpmsRpc.reset!
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_add_save, DFN, "1")
    end
    add_success = RpmsRpc::Problem.add_stock(
      DFN, provider_duz: PROVIDER, vamc: VAMC, fields: { ".01" => "x" }
    )
    assert_equal STOCK_RESULT_KEYS.sort, add_success.keys.sort
    assert add_success[:success]
    assert_nil add_success[:ien]

    RpmsRpc.reset!
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_add_save, DFN, "0^rejected")
    end
    add_failure = RpmsRpc::Problem.add_stock(
      DFN, provider_duz: PROVIDER, vamc: VAMC, fields: { ".01" => "x" }
    )
    assert_equal STOCK_RESULT_KEYS.sort, add_failure.keys.sort
    refute add_failure[:success]
    assert_nil add_failure[:ien]
    assert_equal "0^rejected", add_failure[:raw]

    RpmsRpc.reset!
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_edit_save, IEN, "1")
    end
    update_success = RpmsRpc::Problem.update_stock(
      IEN, provider_duz: PROVIDER, vamc: VAMC,
      changes: { ".01" => "n" }, originals: { ".01" => "o" }
    )
    assert_equal STOCK_RESULT_KEYS.sort, update_success.keys.sort
    assert update_success[:success]
    assert_equal IEN.to_i, update_success[:ien]
  end

  def test_stock_writes_never_dispatch_bgoprob_or_ddr_filer
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_add_save, DFN, "1")
      m.seed_scalar(:problem_edit_save, IEN, "1")
    end

    RpmsRpc::Problem.add_stock(
      DFN, provider_duz: PROVIDER, vamc: VAMC, fields: { ".01" => "x" }
    )
    RpmsRpc::Problem.update_stock(
      IEN, provider_duz: PROVIDER, vamc: VAMC,
      changes: { ".01" => "n" }, originals: { ".01" => "o" }
    )

    refute_bgoprob_or_ddr_calls
  end

  def test_noncanonical_field_number_spellings_are_refused_before_any_rpc
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_add_save, DFN, "1")
      m.seed_scalar(:problem_edit_save, IEN, "1")
    end

    %w[01 0.01 1.0 00].each do |key|
      assert_stock_refused_before_rpc(
        -> {
          RpmsRpc::Problem.add_stock(
            DFN, provider_duz: PROVIDER, vamc: VAMC, fields: { key => "x" }
          )
        }
      )
    end

    [
      { "1" => "a", "01" => "b" },
      { ".01" => "a", "0.01" => "b" },
      { "1" => "a", "1.0" => "b" }
    ].each do |fields|
      assert_stock_refused_before_rpc(
        -> {
          RpmsRpc::Problem.add_stock(
            DFN, provider_duz: PROVIDER, vamc: VAMC, fields: fields
          )
        }
      )
    end

    assert_stock_refused_before_rpc(
      -> {
        RpmsRpc::Problem.add_stock(
          DFN, provider_duz: PROVIDER, vamc: VAMC, fields: { 0.01 => "x" }
        )
      }
    )
    assert_stock_refused_before_rpc(
      -> {
        RpmsRpc::Problem.add_stock(
          DFN, provider_duz: PROVIDER, vamc: VAMC, fields: { 1.0 => "x" }
        )
      }
    )
  end

  def test_canonical_field_number_spellings_are_accepted_on_the_wire
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_add_save, DFN, "1")
    end

    RpmsRpc::Problem.add_stock(
      DFN, provider_duz: PROVIDER, vamc: VAMC,
      fields: { ".01" => "a", "1" => "b", "1.01" => "c", 10 => "d" }
    )
    values = ordered_list_values(RpmsRpc.client.received_calls.last[:params][3])
    assert_equal(
      [
        'GMPFLD(.01)="a"',
        'GMPFLD(1)="b"',
        'GMPFLD(1.01)="c"',
        'GMPFLD(10)="d"'
      ],
      values
    )
  end

  def test_values_and_comments_must_be_valid_utf8_bytes_before_any_rpc
    invalid = "a\xFFb".b

    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_add_save, DFN, "1")
      m.seed_scalar(:problem_edit_save, IEN, "1")
    end

    assert_stock_refused_before_rpc(
      -> {
        RpmsRpc::Problem.add_stock(
          DFN, provider_duz: PROVIDER, vamc: VAMC, fields: { ".01" => invalid }
        )
      }
    )
    assert_stock_refused_before_rpc(
      -> {
        RpmsRpc::Problem.add_stock(
          DFN, provider_duz: PROVIDER, vamc: VAMC,
          fields: { ".01" => "ok" }, comments: [ invalid ]
        )
      }
    )
    assert_stock_refused_before_rpc(
      -> {
        RpmsRpc::Problem.update_stock(
          IEN, provider_duz: PROVIDER, vamc: VAMC,
          changes: { ".01" => invalid }, originals: { ".01" => "was" }
        )
      }
    )
    assert_stock_refused_before_rpc(
      -> {
        RpmsRpc::Problem.update_stock(
          IEN, provider_duz: PROVIDER, vamc: VAMC,
          changes: { ".01" => "now" }, originals: { ".01" => invalid }
        )
      }
    )
    assert_stock_refused_before_rpc(
      -> {
        RpmsRpc::Problem.update_stock(
          IEN, provider_duz: PROVIDER, vamc: VAMC,
          changes: { ".01" => "now" }, originals: { ".01" => "was" },
          comments: [ invalid ]
        )
      }
    )
  end

  def test_update_stock_requires_gmporig_for_every_changed_field_before_any_rpc
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_edit_save, IEN, "1")
    end

    assert_stock_refused_before_rpc(
      -> {
        RpmsRpc::Problem.update_stock(
          IEN, provider_duz: PROVIDER, vamc: VAMC,
          changes: { ".01" => "new" }, originals: {}
        )
      }
    )
    assert_stock_refused_before_rpc(
      -> {
        RpmsRpc::Problem.update_stock(
          IEN, provider_duz: PROVIDER, vamc: VAMC,
          changes: { ".01" => "new", ".05" => "also" }, originals: { ".01" => "old" }
        )
      }
    )
    assert_stock_refused_before_rpc(
      -> {
        RpmsRpc::Problem.update_stock(
          IEN, provider_duz: PROVIDER, vamc: VAMC,
          changes: { ".01" => "new" }, originals: { ".01" => "old", ".05" => "extra" }
        )
      }
    )
  end

  def test_add_stock_and_update_stock_are_non_idempotent_writes_in_retry_safety
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(RpmsRpc::Problem, :add_stock)
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(RpmsRpc::Problem, :update_stock)
    refute RpmsRpc::RetrySafety.auto_retry_safe?(RpmsRpc::Problem, :add_stock)
    refute RpmsRpc::RetrySafety.auto_retry_safe?(RpmsRpc::Problem, :update_stock)
  end

  def test_required_rpcs_lists_orqqpl_add_and_edit_save_under_problem
    required = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    problem_rpcs = required.fetch("modules").fetch("RpmsRpc::Problem")

    assert_includes problem_rpcs, "ORQQPL ADD SAVE"
    assert_includes problem_rpcs, "ORQQPL EDIT SAVE"
  end

  private

  def assert_stock_result_shape(result)
    assert_equal STOCK_RESULT_KEYS.sort, result.keys.sort
  end

  def assert_stock_refused_before_rpc(invoke)
    RpmsRpc.client.received_calls.clear
    result = invoke.call
    assert_equal STOCK_REFUSAL, result
    assert_empty RpmsRpc.client.received_calls,
      "unsafe input must fail closed before ORQQPL (ORQQPL1.m:160,:120)"
  end

  def refute_bgoprob_or_ddr_calls
    forbidden = RpmsRpc.client.received_calls.map { |c| c[:rpc] }.grep(/\ABGO|DDR FILER/)
    assert_empty forbidden, "stock writes must not use BGOPROB or DDR FILER: #{forbidden.inspect}"
  end

  def list_keys(list_param)
    entries = list_entries(list_param)
    entries.keys.map { |k| Integer(k.to_s) }
  end

  def ordered_list_values(list_param)
    entries = list_entries(list_param)
    entries.keys.map(&:to_s).sort_by { |k| Integer(k) }.map { |k| entries[k] || entries[Integer(k)] }
  end

  def list_entries(list_param)
    case list_param
    when Hash
      if list_param[:type] == :list
        list_param[:entries]
      else
        list_param
      end
    when Array
      list_param.each_with_index.to_h { |v, i| [ (i + 1).to_s, v ] }
    else
      flunk "expected list param, got #{list_param.inspect}"
    end
  end

  def assert_balanced_gmpfld_literal(line)
    assert_match(/\A(GMPFLD|GMPORIG)\(.+\)=".*"\z/, line)
    inner = line[line.index('="') + 2..-2]
    i = 0
    while i < inner.length
      if inner[i] == '"' && inner[i + 1] == '"'
        i += 2
      elsif inner[i] == '"'
        flunk "unescaped quote inside literal: #{line.inspect}"
      else
        i += 1
      end
    end
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/order"

# rpms-rpc#455: Order.save over ORWDX SAVE (SAVE^ORWDX -> EN^ORCSAVE, ORWDX.m:128-130).
#
# Broker formals (FOIA-RPMS ORWDX.m:80, CivicActions): SAVE(REC,ORVP,ORNP,ORL,DLG,ORDG,
# ORIT,ORIFN,ORDIALOG,ORDEA,ORAPPT,ORSRC) — eleven client actuals after REC. Stock
# VistA (ORWDX.m:52) adds OREVTDF as a 13th formal; FOIA-RPMS lacks it, so sending
# OREVTDF raises "too many actual parameters" on RPMS. Reply REC is filled by
# GETBYIFN^ORWORR / GETFLDS (ORWORR.m:139-150); empty when ORIFN stays empty after
# save (ORWDX.m:130-131, ORWORR.m:133).
class OrderSaveTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")
  RPC = "ORWDX SAVE"

  DFN = "8791"
  PROVIDER_DUZ = "301"
  LOCATION = "349"

  # Synthetic dialog prompt IENs (not site-specific).
  P_ORDERABLE = 4
  P_DOSE = 15
  P_ROUTE = 16
  P_SCHEDULE = 17
  P_SUPPLY = 18
  P_QUANTITY = 19
  P_REFILLS = 20
  P_SIG = 21

  P_LAB_SPECIMEN = 31
  P_LAB_SAMPLE = 32
  P_LAB_URGENCY = 33
  P_LAB_COLLECTION = 34
  P_LAB_START = 35

  P_IMG_URGENCY = 41
  P_IMG_TRANSPORT = 42
  P_IMG_CATEGORY = 43
  P_IMG_REASON = 44

  MED_DIALOG = "PSO OERR"
  MED_RESPONSES = {
    [ P_ORDERABLE, 1 ] => "92001",
    [ P_DOSE, 1 ] => "1 TAB",
    [ P_ROUTE, 1 ] => "PO",
    [ P_SCHEDULE, 1 ] => "DAILY",
    [ P_SUPPLY, 1 ] => "30",
    [ P_QUANTITY, 1 ] => "30",
    [ P_REFILLS, 1 ] => "0",
    [ P_SIG, 1 ] => %(ORDIALOG("WP",#{P_SIG},1)),
    [ "WP", P_SIG, 1, 1, 0 ] => "TAKE 1 TABLET BY MOUTH DAILY"
  }.freeze

  LAB_DIALOG = "LR OTHER LAB TESTS"
  LAB_RESPONSES = {
    [ P_ORDERABLE, 1 ] => "93001",
    [ P_LAB_SPECIMEN, 1 ] => "BLOOD",
    [ P_LAB_SAMPLE, 1 ] => "SERUM",
    [ P_LAB_URGENCY, 1 ] => "ROUTINE",
    [ P_LAB_COLLECTION, 1 ] => "WC",
    [ P_LAB_START, 1 ] => "TODAY"
  }.freeze

  IMG_DIALOG = "RA OERR EXAM"
  IMG_RESPONSES = {
    [ P_ORDERABLE, 1 ] => "94001",
    [ P_IMG_URGENCY, 1 ] => "ROUTINE",
    [ P_IMG_TRANSPORT, 1 ] => "AMBULATORY",
    [ P_IMG_CATEGORY, 1 ] => "CHEST",
    [ P_IMG_REASON, 1 ] => %(ORDIALOG("WP",#{P_IMG_REASON},1)),
    [ "WP", P_IMG_REASON, 1, 1, 0 ] => "Synthetic indication for imaging order"
  }.freeze

  SAVE_HEADER = "~12345;1^5^3251022.1200^^^11^SIG SYNTH^^^301^PROVIDER,TEST^1^0"
  # GETFLDS order text lines are "t"-prefixed on the wire (ORWORR.m:165-169).
  SAVE_TEXT_LINES_WIRE = [
    "tOUTPATIENT MEDICATIONS",
    "tASPIRIN 81MG TAB  1 TAB PO DAILY"
  ].freeze
  SAVE_TEXT_LINES = [
    "OUTPATIENT MEDICATIONS",
    "ASPIRIN 81MG TAB  1 TAB PO DAILY"
  ].freeze

  def teardown
    RpmsRpc.reset!
  end

  # --- ORWDX SAVE frame (FOIA-RPMS ORWDX.m:80) ----------------------------------

  def test_save_dispatches_orwdx_save_with_eleven_formals_and_empty_orifn
    with_orwdx_save_wire([ SAVE_HEADER ] + SAVE_TEXT_LINES_WIRE)
    responses = { [ P_ORDERABLE, 1 ] => "92001" }

    RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, responses)

    call = save_call
    refute_nil call, "#{RPC} was not called"
    assert_equal 11, call[:params].length, "eleven client actuals after REC (FOIA-RPMS ORWDX.m:80)"
    assert_equal DFN, call[:params][0]
    assert_equal PROVIDER_DUZ, call[:params][1]
    assert_equal LOCATION, call[:params][2]
    assert_equal MED_DIALOG, call[:params][3]
    assert_equal "", call[:params][4], "display group ORDG"
    assert_equal "", call[:params][5], "quick order ORIT"
    assert_equal "", call[:params][6], "new order ORIFN (ORWDX.m:128)"
    assert_ordialog_list_param(call[:params][7], responses)
    assert_equal "", call[:params][8], "ORDEA"
    assert_equal "", call[:params][9], "ORAPPT"
    assert_equal "", call[:params][10], "ORSRC"
    refute call[:params][11], "must not send OREVTDF (stock-only 13th formal)"
  end

  def test_save_passes_display_group_and_quick_order_when_given
    with_orwdx_save_wire([ SAVE_HEADER ])
    responses = { [ P_ORDERABLE, 1 ] => "92001" }

    RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, responses,
                         display_group: "5", quick_order: "7")

    call = save_call
    assert_equal "5", call[:params][4]
    assert_equal "7", call[:params][5]
  end

  def test_save_sends_integer_display_group_and_string_quick_order_as_canonical_decimals
    with_orwdx_save_wire([ SAVE_HEADER ])
    responses = { [ P_ORDERABLE, 1 ] => "92001" }

    RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, responses,
                         display_group: 5, quick_order: "7")

    call = save_call
    assert_equal "5", call[:params][4]
    assert_equal "7", call[:params][5]
  end

  # --- dialog fixtures: ORDIALOG list shape -----------------------------------

  def test_save_pso_oerr_sends_medication_ordialog_list_shape
    with_orwdx_save_wire([ SAVE_HEADER ])
    RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, MED_RESPONSES)

    assert_ordialog_list_param(save_call[:params][7], MED_RESPONSES)
  end

  def test_save_lr_other_lab_tests_sends_lab_ordialog_list_shape
    with_orwdx_save_wire([ SAVE_HEADER ])
    RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, LAB_DIALOG, LAB_RESPONSES)

    assert_ordialog_list_param(save_call[:params][7], LAB_RESPONSES)
  end

  def test_save_ra_oerr_exam_sends_imaging_ordialog_list_shape
    with_orwdx_save_wire([ SAVE_HEADER ])
    RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, IMG_DIALOG, IMG_RESPONSES)

    assert_ordialog_list_param(save_call[:params][7], IMG_RESPONSES)
  end

  # --- GETFLDS reply (ORWORR.m:139-150) ---------------------------------------

  def test_save_parses_unsigned_reply_with_order_text_lines
    with_orwdx_save_wire([ SAVE_HEADER ] + SAVE_TEXT_LINES_WIRE)

    result = RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, MED_RESPONSES)

    assert result[:success]
    assert_equal "12345;1", result[:order_id]
    assert_equal 12_345, result[:ien]
    assert_equal 11, result[:status]
    assert_equal SAVE_TEXT_LINES, result[:text]
  end

  def test_save_delayed_status_ten_is_success
    header = "~12345;1^5^3251022.1200^^^10^delayed synthetic"
    with_orwdx_save_wire([ header ])

    result = RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, MED_RESPONSES)

    assert result[:success]
    assert_equal 10, result[:status]
  end

  def test_save_active_or_pending_status_fails_closed_as_released
    {
      6 => "ACTIVE",
      5 => "PENDING"
    }.each do |status, label|
      RpmsRpc.reset!
      header = "~12345;1^5^3251022.1200^^^#{status}^#{label}"
      with_orwdx_save_wire([ header ])

      result = RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, MED_RESPONSES)

      refute result[:success]
      assert_equal :released, result[:error]
      assert_match(/#{label}/i, result[:message])
    end
  end

  # --- empty / malformed REC (fail closed) ------------------------------------

  def test_save_empty_reply_is_empty_reply_not_success
    [ [], "", nil ].each do |reply|
      RpmsRpc.reset!
      with_orwdx_save_wire(reply)

      result = RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, MED_RESPONSES)

      refute result[:success]
      assert_equal :empty_reply, result[:error]
    end
  end

  def test_save_malformed_first_line_is_malformed_reply_not_success
    [
      "12345^5^3251022.1200^^^11^missing tilde",
      "~abc;1^5^3251022.1200^^^11^bad ifn",
      "~12345;1^5^t^^^x^non_integer_status",
      "~12345;0^5^^^^11",
      ";01"
    ].each do |line|
      RpmsRpc.reset!
      with_orwdx_save_wire([ line ])

      result = RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, MED_RESPONSES)

      refute result[:success]
      assert_equal :malformed_reply, result[:error]
    end
  end

  def test_save_status_with_leading_zero_is_malformed_reply_not_success
    header = "~12345;1^5^3251022.1200^^^011^SIG SYNTH"
    with_orwdx_save_wire([ header ])

    result = RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, MED_RESPONSES)

    refute result[:success]
    assert_equal :malformed_reply, result[:error]
  end

  def test_save_parses_t_prefixed_text_stops_at_pipe_and_ignores_pki_xml
    header = SAVE_HEADER
    wire_lines = [
      header,
      "t+ASPIRIN 81MG TAB",
      "t1 TAB PO DAILY",
      "|",
      "x<xml/>"
    ]
    with_orwdx_save_wire(wire_lines)

    result = RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, MED_RESPONSES)

    assert result[:success]
    assert_equal [ "+ASPIRIN 81MG TAB", "1 TAB PO DAILY" ], result[:text]
  end

  def test_save_text_line_before_pipe_without_t_prefix_is_malformed_reply
    header = SAVE_HEADER
    with_orwdx_save_wire([ header, "OUTPATIENT MEDICATIONS", "|" ])

    result = RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, MED_RESPONSES)

    refute result[:success]
    assert_equal :malformed_reply, result[:error]
  end

  # --- argument validation (no RPC) -------------------------------------------

  def test_save_invalid_arguments_never_call_rpc
    client = no_wire_client
    RpmsRpc.configure { |c| c.client = client }
    base = [ PROVIDER_DUZ, LOCATION, MED_DIALOG, MED_RESPONSES ]

    invalid_dfns = [ nil, "", "0", "abc", "12abc", " 5" ]
    invalid_dfns.each do |dfn|
      client.calls.clear
      result = RpmsRpc::Order.save(dfn, *base)
      refute result[:success]
      assert_equal :invalid_argument, result[:error]
      assert_empty client.calls
    end

    [ nil, "", "0", "abc" ].each do |duz|
      client.calls.clear
      result = RpmsRpc::Order.save(DFN, duz, LOCATION, MED_DIALOG, MED_RESPONSES)
      refute result[:success]
      assert_equal :invalid_argument, result[:error]
      assert_empty client.calls
    end

    [ nil, "", "0", "abc" ].each do |loc|
      client.calls.clear
      result = RpmsRpc::Order.save(DFN, PROVIDER_DUZ, loc, MED_DIALOG, MED_RESPONSES)
      refute result[:success]
      assert_equal :invalid_argument, result[:error]
      assert_empty client.calls
    end

    [ nil, "", "   " ].each do |dialog|
      client.calls.clear
      result = RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, dialog, MED_RESPONSES)
      refute result[:success]
      assert_equal :invalid_argument, result[:error]
      assert_empty client.calls
    end

    [ nil, {}, { foo: "bar" }, { [ "not", "array" ] => "1" } ].each do |responses|
      client.calls.clear
      result = RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, responses)
      refute result[:success]
      assert_equal :invalid_argument, result[:error]
      assert_empty client.calls
    end
  end

  def test_save_rejects_order_dialog_values_that_must_not_reach_m
    assert_save_invalid_never_calls_rpc(
      dialogs: [
        "PSO OERR^I",
        "PSO OERR\r\nX",
        "PSO OERR\x00",
        " PSO OERR "
      ]
    ) { |dialog| [ DFN, PROVIDER_DUZ, LOCATION, dialog, { [ P_ORDERABLE, 1 ] => "92001" } ] }
  end

  def test_save_rejects_display_group_values_that_must_not_reach_m
    minimal = { [ P_ORDERABLE, 1 ] => "92001" }
    assert_save_invalid_never_calls_rpc(
      cases: [ "5^99^X", :oops, "0", "05", -1 ]
    ) { |ordg| [ DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, minimal, { display_group: ordg, quick_order: "" } ] }
  end

  def test_save_rejects_quick_order_values_that_must_not_reach_m
    minimal = { [ P_ORDERABLE, 1 ] => "92001" }
    assert_save_invalid_never_calls_rpc(cases: [ "-7\x00", "7^1" ]) do |orit|
      [ DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, minimal, { display_group: "", quick_order: orit } ]
    end
  end

  def test_save_rejects_non_string_non_integer_response_values
    assert_save_invalid_never_calls_rpc(
      responses: [
        { [ P_ORDERABLE, 1 ] => nil },
        { [ P_ORDERABLE, 1 ] => { a: 1 } }
      ]
    ) { |responses| [ DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, responses ] }
  end

  def test_save_rejects_response_string_values_with_caret_or_control_characters
    assert_save_invalid_never_calls_rpc(
      responses: [
        { [ P_ORDERABLE, 1 ] => "92001^EXTRA" },
        { [ P_ORDERABLE, 1 ] => "92001\x1e" },
        { [ P_ORDERABLE, 1 ] => "a\nb" }
      ]
    ) { |responses| [ DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, responses ] }
  end

  def test_save_rejects_duplicate_ordialog_subscripts_in_one_hash
    duplicate = { [ P_ORDERABLE, 1 ] => "92001", [ "4", "1" ] => "92002" }
    assert_save_invalid_never_calls_rpc(
      responses: [ duplicate ]
    ) { |responses| [ DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, responses ] }
  end

  def test_save_positive_integer_ids_still_call_rpc
    with_orwdx_save_wire([ SAVE_HEADER ])

    RpmsRpc::Order.save(8791, 301, 349, MED_DIALOG, MED_RESPONSES)

    call = save_call
    assert_equal "8791", call[:params][0]
    assert_equal "301", call[:params][1]
    assert_equal "349", call[:params][2]
  end

  # --- only SAVE, never SEND ----------------------------------------------------

  def test_save_never_dispatches_orwdx_send_or_other_rpcs
    with_orwdx_save_wire([ SAVE_HEADER ])

    RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, MED_RESPONSES)

    calls = RpmsRpc.client.received_calls
    assert_equal 1, calls.length
    assert_equal RPC, calls.first[:rpc]
    refute calls.any? { |c| c[:rpc] == "ORWDX SEND" }
  end

  # --- retry safety / compatibility registry ----------------------------------

  def test_save_is_non_idempotent_write
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(RpmsRpc::Order, :save)
  end

  def test_required_rpcs_includes_orwdx_save_on_order
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    rpcs = doc.fetch("modules").fetch("RpmsRpc::Order")
    assert_includes rpcs, RPC
  end

  private

  def save_call
    RpmsRpc.client.received_calls.find { |c| c[:rpc] == RPC }
  end

  def assert_ordialog_list_param(param, expected_entries)
    actual = ordialog_entries(param)
    expected = expected_entries.transform_keys { |k| normalize_ordialog_key(k) }
    assert_equal expected, actual
  end

  def ordialog_entries(param)
    case param
    when Hash
      if param[:type] == :list
        return normalize_ordialog_hash(param[:entries])
      end

      normalize_ordialog_hash(param)
    else
      flunk "expected ORDIALOG list param, got #{param.inspect}"
    end
  end

  def normalize_ordialog_hash(hash)
    hash.transform_keys { |k| normalize_ordialog_key(k) }
        .transform_values(&:to_s)
  end

  def normalize_ordialog_key(key)
    case key
    when Array
      key.map { |level| level.is_a?(Numeric) ? level : level.to_s }
    else
      key.to_s
    end
  end

  def with_orwdx_save_wire(lines)
    wire = lines.nil? ? nil : (lines.is_a?(Array) ? lines : [ lines ])
    with_orwdx_save_sequence([ wire ])
  end

  def with_orwdx_save_sequence(wires)
    client = RpmsRpc::MockClient.new
    queue = wires.map { |wire| wire.nil? ? nil : wire }
    %i[call_rpc call_rpc_lines call_rpc_global_array].each do |meth|
      client.define_singleton_method(meth) do |rpc_name, *params|
        received_calls << { rpc: rpc_name, params: params, context: current_context }
        raise "unexpected RPC #{rpc_name.inspect}" unless rpc_name == RPC

        if queue.empty?
          raise "unexpected extra #{RPC} call"
        end

        queue.shift
      end
    end
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def assert_save_invalid_never_calls_rpc(cases: nil, dialogs: nil, responses: nil)
    client = no_wire_client
    RpmsRpc.configure { |c| c.client = client }
    items = cases || dialogs || responses
    items.each do |item|
      client.calls.clear
      args = yield(item)
      opts = args.last.is_a?(Hash) && args.last.key?(:display_group) ? args.pop : {}
      result = RpmsRpc::Order.save(*args, **opts)
      refute result[:success], item.inspect
      assert_equal :invalid_argument, result[:error]
      assert_empty client.calls
    end
  end

  def no_wire_client
    Class.new do
      attr_reader :calls

      def initialize = @calls = []

      %i[call_rpc call_rpc_lines call_rpc_global_array].each do |meth|
        define_method(meth) do |rpc, *params|
          @calls << [ rpc, *params ]
          raise "RPC must not run for invalid Order.save arguments"
        end
      end
    end.new
  end
end

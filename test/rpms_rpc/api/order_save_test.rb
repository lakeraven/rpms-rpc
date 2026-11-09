# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/order"
require_relative "../captured_replies"

# rpms-rpc#455: Order.save over ORWDX SAVE (SAVE^ORWDX -> EN^ORCSAVE, ORWDX.m:128-130).
#
# Broker formals (FOIA-RPMS ORWDX.m:80, CivicActions): SAVE(REC,ORVP,ORNP,ORL,DLG,ORDG,
# ORIT,ORIFN,ORDIALOG,ORDEA,ORAPPT,ORSRC) — eleven client actuals after REC. Stock
# VistA (ORWDX.m:52) adds OREVTDF as a 13th formal; FOIA-RPMS lacks it, so sending
# OREVTDF raises "too many actual parameters" on RPMS. Reply REC is filled by
# GETBYIFN^ORWORR / GETFLDS (ORWORR.m:139-150); empty when ORIFN stays empty after
# save (ORWDX.m:130-131, ORWORR.m:133).
#
# The reply is the pinned build's: Order.save run as PROFILE,MD on seed patient
# DFN 990034 with the OR GXTEXT WORD PROCESSING ORDER dialog, recorded as the
# "save" flow of test/fixtures/captured_replies/order-write.yml and replayed
# through CiaClient. The guard cases keep that captured frame and change one
# piece of its GETFLDS reply; each says what it changes. The live spec
# (test/live/order_write_live_test.rb) proves the order is on file.
class OrderSaveTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")
  RPC = "ORWDX SAVE"
  SLUG = "order-write"

  SAVED = CapturedReplies.flow_calls(SLUG, "save").first.last
  DFN, PROVIDER_DUZ, LOCATION, DIALOG, DISPLAY_GROUP = SAVED.first(5)
  RESPONSES = SAVED[7]

  # Synthetic dialog prompt IENs for the argument guards (not site-specific).
  P_ORDERABLE = 4
  MED_DIALOG = "PSO OERR"
  MED_RESPONSES = { [ P_ORDERABLE, 1 ] => "92001", [ 15, 1 ] => "1 TAB", [ 21, 1 ] => %(ORDIALOG("WP",21,1)),
                    [ "WP", 21, 1, 1, 0 ] => "TAKE 1 TABLET BY MOUTH DAILY" }.freeze

  def teardown
    RpmsRpc.reset!
  end

  # The captured ORWDX SAVE reply, or that frame with its body replaced.
  def captured_save = CapturedReplies.flow_script(SLUG, "save").fetch(RPC).first

  def with_body(body) = captured_save.byteslice(0, 2) + body.b

  def replay(reply = captured_save)
    @client = CapturedReplies::ReplayCiaClient.new(RPC => [ reply ])
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = @client }
    @client
  end

  def save(responses = RESPONSES, **opts)
    RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, DIALOG, responses, display_group: DISPLAY_GROUP, **opts)
  end

  def save_call = @client.calls.find { |c| c[:rpc] == RPC }

  # --- ORWDX SAVE frame (FOIA-RPMS ORWDX.m:80) ----------------------------------

  def test_save_sends_the_eleven_formals_the_build_answered
    replay
    save

    assert_equal SAVED, save_call[:params], "eleven client actuals after REC (FOIA-RPMS ORWDX.m:80)"
    assert_equal "", save_call[:params][6], "new order ORIFN (ORWDX.m:128)"
    refute save_call[:params][11], "must not send OREVTDF (stock-only 13th formal)"
  end

  def test_save_passes_display_group_and_quick_order_when_given
    replay
    RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, DIALOG, RESPONSES, display_group: 5, quick_order: "7")

    assert_equal [ "5", "7" ], save_call[:params][4, 2]
  end

  # The ORDIALOG responses go to the wire as given, as a list.
  def test_save_sends_the_ordialog_responses_as_given
    replay
    RpmsRpc::Order.save(DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, MED_RESPONSES)

    assert_equal MED_RESPONSES, save_call[:params][7]
  end

  # --- GETFLDS reply (ORWORR.m:139-150) ---------------------------------------

  def test_save_parses_the_unsigned_order_and_its_text
    replay

    result = save

    assert result[:success]
    assert_match(/\A\d+;1\z/, result[:order_id])
    assert_equal result[:order_id].to_i, result[:ien]
    assert_equal RpmsRpc::Order::SAVE_STATUS_UNRELEASED, result[:status]
    assert_includes result[:text].first, "rpms-rpc captured order"
  end

  def test_save_never_dispatches_orwdx_send_or_other_rpcs
    replay
    save

    assert_equal [ RPC ], @client.rpcs_called
  end

  # Guard: piece 6 (status) set to 10, DELAYED: still a saved order.
  def test_save_delayed_status_ten_is_success
    replay(with_body(captured_body.sub("^^11^".b, "^^10^".b)))

    result = save

    assert result[:success]
    assert_equal 10, result[:status]
  end

  # Guard: piece 6 set to 6 (ACTIVE) or 5 (PENDING): the order was released,
  # which a save must not do, so it fails closed.
  def test_save_active_or_pending_status_fails_closed_as_released
    { 6 => "ACTIVE", 5 => "PENDING" }.each do |status, label|
      replay(with_body(captured_body.sub("^^11^".b, "^^#{status}^".b)))

      result = save

      refute result[:success]
      assert_equal :released, result[:error]
      assert_match(/#{label}/i, result[:message])
    end
  end

  # Guard: the frame with no body (ORIFN stayed empty, ORWDX.m:130-131).
  def test_save_empty_reply_is_empty_reply_not_success
    replay(with_body(""))

    result = save

    refute result[:success]
    assert_equal :empty_reply, result[:error]
  end

  # Guard: the header line changed so it is not a GETFLDS order line.
  def test_save_malformed_first_line_is_malformed_reply_not_success
    [ ->(b) { b.sub("~".b, "".b) }, ->(b) { b.sub(/\A~\d+/n, "~abc") }, ->(b) { b.sub("^^11^".b, "^^011^".b) } ].each do |change|
      replay(with_body(change.call(captured_body)))

      result = save

      refute result[:success]
      assert_equal :malformed_reply, result[:error]
    end
  end

  # Guard: an order text line without its "t" prefix (ORWORR.m:165-169).
  def test_save_text_line_without_t_prefix_is_malformed_reply
    replay(with_body(captured_body.sub("\rt>>".b, "\r>>".b)))

    result = save

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

  def test_save_rejects_response_string_value_with_delete_character
    assert_save_invalid_never_calls_rpc(
      responses: [ { [ P_ORDERABLE, 1 ] => "92001\x7f" } ]
    ) { |responses| [ DFN, PROVIDER_DUZ, LOCATION, MED_DIALOG, responses ] }
  end

  def test_save_rejects_negative_ordialog_subscript_keys
    assert_save_invalid_never_calls_rpc(
      responses: [
        { [ -4, 1 ] => "92001" },
        { [ "-4", "1" ] => "92001" }
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
    replay
    RpmsRpc::Order.save(DFN.to_i, PROVIDER_DUZ.to_i, LOCATION.to_i, DIALOG, RESPONSES, display_group: DISPLAY_GROUP)

    assert_equal [ DFN, PROVIDER_DUZ, LOCATION ], save_call[:params].first(3)
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

  def captured_body = captured_save.byteslice(2..)

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

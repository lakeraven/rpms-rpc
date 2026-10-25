# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/xwb_client"
require "rpms_rpc/bmx_client"
require "rpms_rpc/api/pov"
require "rpms_rpc/api/procedure"
require "rpms_rpc/api/problem"
require "rpms_rpc/api/e_signature"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/registration"
require "rpms_rpc/api/referral"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/exam_component"
require "rpms_rpc/api/health_factor"
require "rpms_rpc/api/immunization_refusal"
require "rpms_rpc/api/allergy"
require "rpms_rpc/api/progress_note"
require "rpms_rpc/api/order"

# #472 / #474, panel round 2. A value the wire would mis-frame is refused
# before anything is sent (Client::FrameTooLongError). The write APIs whose own
# contract is a failure hash must answer with that hash, over EVERY client:
# the first round only exercised XWB, so a rescue narrowed to the XWB class
# still passed. APIs whose contract is to raise are not in this file.
class OversizedTextWritersTest < Minitest::Test
  class RecordingSocket
    attr_reader :writes

    def initialize
      @writes = []
    end

    def write(str)
      @writes << str.b
      str.bytesize
    end

    def recv(_n) = ""
    def flush; end
    def close; end
    def closed? = false
    def setsockopt(*); end
  end

  XWB_TEXT = "n" * 1000 # over the 999-byte L-PACK limit
  BMX_TEXT = "n" * 600  # over the 512-byte BMX request cap

  def setup
    @restore = []
    @socket = RecordingSocket.new
  end

  def teardown
    @restore.reverse_each(&:call)
    RpmsRpc.reset!
  end

  def use_xwb
    client = RpmsRpc::XwbClient.new
    install(client)
    "999"
  end

  def use_bmx
    client = RpmsRpc::BmxClient.new
    client.instance_variable_set(:@timeout, 1)
    install(client)
    "512"
  end

  def install(client)
    client.instance_variable_set(:@socket, @socket)
    client.instance_variable_set(:@connected, true)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
  end

  def long_for(limit) = limit == "999" ? XWB_TEXT : BMX_TEXT

  # The suite avoids Object#stub (Minitest 6 dropped it): swap a singleton method and put it back.
  def replace_singleton(target, name, &body)
    original = target.method(name)
    target.define_singleton_method(name, &body)
    @restore << -> { target.define_singleton_method(name, original) }
  end

  # The scheduling and referral writes bind an option first; that round trip is
  # not what these tests are about, so run the block straight through.
  def skip_context_binding
    replace_singleton(RpmsRpc::ContextScope, :scoped) { |_client, _context, &block| block.call }
  end

  def assert_refused(result, limit, text)
    assert_equal false, result[:success]
    assert_match(/#{limit}/, result[:error].to_s, "the failure must name the byte limit")
    refute_includes result[:error].to_s, text, "the text itself must never be echoed"
    assert_empty @socket.writes, "nothing is sent when the value cannot be framed"
  end

  # -- BGO visit-entry writes: the siblings of ExamComponent and HealthFactor --

  def test_exam_component_add_returns_its_failure_shape_over_bmx
    limit = use_bmx
    result = RpmsRpc::ExamComponent.add("8791", "2090060", "77", finding: "NORMAL", narrative: BMX_TEXT)
    assert_refused(result, limit, BMX_TEXT)
    assert_equal({ success: false, ien: nil, raw: nil }, result.slice(:success, :ien, :raw))
  end

  [ [ "xwb", :use_xwb ], [ "bmx", :use_bmx ] ].each do |name, user|
    define_method("test_pov_add_returns_its_failure_shape_over_#{name}") do
      limit = send(user)
      text = long_for(limit)
      result = RpmsRpc::Pov.add("8791", "2090060", "250.00", narrative: text)
      assert_refused(result, limit, text)
      assert_equal({ success: false, ien: nil, raw: nil }, result.slice(:success, :ien, :raw))
    end

    define_method("test_procedure_add_returns_its_failure_shape_over_#{name}") do
      limit = send(user)
      text = long_for(limit)
      result = RpmsRpc::Procedure.add("8791", "2090060", "99213", narrative: text)
      assert_refused(result, limit, text)
      assert_equal({ success: false, ien: nil, raw: nil }, result.slice(:success, :ien, :raw))
    end

    define_method("test_problem_delete_returns_its_failure_shape_over_#{name}") do
      limit = send(user)
      text = long_for(limit)
      result = RpmsRpc::Problem.delete("8791", "77", reason: text)
      assert_refused(result, limit, text)
      assert_equal({ success: false, ien: nil, raw: nil }, result.slice(:success, :ien, :raw))
    end

    define_method("test_e_signature_remove_returns_its_failure_shape_over_#{name}") do
      limit = send(user)
      text = long_for(limit)
      result = RpmsRpc::ESignature.remove("5001", "12", reason: text)
      assert_refused(result, limit, text)
      assert_equal({ success: false, raw: nil }, result.slice(:success, :raw))
    end
  end

  # Problem add/update send a list parameter, which the BMX client does not
  # support at all (it raises NotImplementedError before any size check), so
  # only XWB can reach the size refusal.
  def test_problem_add_returns_its_failure_shape_over_xwb
    limit = use_xwb
    result = RpmsRpc::Problem.add("8791", { icd_code: "250.00", location_ien: "1", description: XWB_TEXT })
    assert_refused(result, limit, XWB_TEXT)
    assert_equal({ success: false, ien: nil, raw: nil }, result.slice(:success, :ien, :raw))
  end

  def test_problem_update_returns_its_failure_shape_over_xwb
    limit = use_xwb
    result = RpmsRpc::Problem.update("8791", "77", { description: XWB_TEXT })
    assert_refused(result, limit, XWB_TEXT)
    assert_equal({ success: false, ien: nil, raw: nil }, result.slice(:success, :ien, :raw))
  end

  # List parameter on OREDITED — BMX cannot frame it (#472); only XWB reaches refusal.
  def test_allergy_save_returns_its_failure_shape_over_xwb
    limit = use_xwb
    allergy = {
      agent: "PENICILLIN",
      agent_pointer: "125;PSNDF(50.6,",
      type: "D",
      nature: "A",
      originator: "42",
      originated_at: "3261015.1045",
      observed_or_historical: "o",
      comments: [ XWB_TEXT ]
    }
    result = RpmsRpc::Allergy.save("8791", allergy)
    assert_equal false, result[:success]
    assert_equal :frame_too_long, result[:error]
    assert_match(/#{limit}/, result[:message].to_s)
    refute_includes result[:message].to_s, XWB_TEXT
    assert_empty @socket.writes, "nothing is sent when the value cannot be framed"
    refute result.key?(:note_ien), "refusal is not a broker success"
  end

  def test_no_known_allergies_returns_its_failure_shape_over_xwb
    limit = use_xwb
    long_dfn = "1" + ("0" * 999)
    result = RpmsRpc::Allergy.no_known_allergies(long_dfn)
    assert_equal false, result[:success]
    assert_equal :frame_too_long, result[:error]
    assert_match(/#{limit}/, result[:message].to_s)
    refute_includes result[:message].to_s, long_dfn
    assert_empty @socket.writes, "nothing is sent when the value cannot be framed"
    refute result.key?(:note_ien), "refusal is not a broker success"
  end

  def test_problem_add_stock_returns_its_failure_shape_over_xwb
    use_xwb
    fields = {
      ".01" => "5042",
      "1.01" => "1^Unresolved",
      ".05" => XWB_TEXT,
      ".12" => "A",
      ".13" => "1"
    }
    result = RpmsRpc::Problem.add_stock("8791", provider_duz: "301", vamc: "7", fields: fields)
    assert_equal false, result[:success]
    assert_equal :frame_too_long, result[:error]
    assert_match(/999/, result[:message].to_s)
    refute_includes result[:message].to_s, XWB_TEXT
    assert_equal({ success: false, ien: nil, raw: nil }, result.slice(:success, :ien, :raw))
    assert_empty @socket.writes
  end

  def test_problem_update_stock_returns_its_failure_shape_over_xwb
    use_xwb
    originals = {
      ".01" => "5042",
      "1.01" => "1^Unresolved",
      ".05" => "1^Synthetic problem narrative",
      ".12" => "A",
      "1.02" => "T",
      "80001" => "",
      "80002" => "",
      "80003" => "",
      "80004" => "",
      "80005" => "",
      "80201" => "3251025^10/25/2025",
      "80202" => "10D^10D"
    }
    result = RpmsRpc::Problem.update_stock(
      "77", provider_duz: "301", vamc: "7",
      changes: { ".05" => XWB_TEXT },
      originals: originals
    )
    assert_equal false, result[:success]
    assert_equal :frame_too_long, result[:error]
    assert_match(/999/, result[:message].to_s)
    refute_includes result[:message].to_s, XWB_TEXT
    assert_equal({ success: false, ien: nil, raw: nil }, result.slice(:success, :ien, :raw))
    assert_empty @socket.writes
  end

  # ORWDX SAVE sends an ORDIALOG list parameter; BMX cannot frame list params.
  def test_order_save_returns_frame_too_long_failure_shape_over_xwb
    limit = use_xwb
    responses = { [ 4, 1 ] => XWB_TEXT }
    result = RpmsRpc::Order.save("8791", "301", "349", "PSO OERR", responses)

    assert_equal false, result[:success]
    assert_equal :frame_too_long, result[:error]
    assert_match(/#{limit}/, result[:message].to_s)
    refute_includes result[:message].to_s, XWB_TEXT
    assert_empty @socket.writes
  end

  def test_problem_still_raises_for_a_caller_bug
    use_xwb
    assert_raises(ArgumentError) { RpmsRpc::Problem.add("8791", "not a hash") }
  end

  # -- Scheduling: its module contract is { success: false, error: String } --

  [ [ "xwb", :use_xwb ], [ "bmx", :use_bmx ] ].each do |name, user|
    define_method("test_scheduling_add_appointment_answers_with_an_error_hash_over_#{name}") do
      skip_context_binding
      limit = send(user)
      text = long_for(limit)
      result = RpmsRpc::Scheduling.add_appointment(
        patient_dfn: "8791", resource: "CLINIC A", start_time: "3261023.0900",
        end_time: "3261023.0930", length_minutes: 30, note: text
      )
      assert_refused(result, limit, text)
    end

    define_method("test_scheduling_cancel_appointment_answers_with_an_error_hash_over_#{name}") do
      skip_context_binding
      limit = send(user)
      text = long_for(limit)
      result = RpmsRpc::Scheduling.cancel_appointment("55", reason: "3", note: text)
      assert_refused(result, limit, text)
    end
  end

  # -- Registration.update: a refused window keeps the filed_windows report --

  def test_registration_update_reports_the_windows_filed_before_a_refused_one
    limit = use_xwb
    calls = []
    replace_singleton(RpmsRpc::Agg, :editing) { |**_kw, &block| block.call }
    replace_singleton(RpmsRpc::Agg, :update_patient) do |window:, dfn:, params:, **_kw|
      calls << window
      if calls.size == 1
        { success: true }
      else
        RpmsRpc.client.call_rpc("AGG UPDATE PATIENT", params.values.first)
      end
    end

    result = RpmsRpc::Registration.update("8791", birth_city: "Springfield", address_line1: "a" * 1000)

    assert_equal false, result[:success]
    assert_equal :frame_too_long, result[:error]
    assert_equal 1, result[:filed_windows].size, "the window filed before the refusal is reported"
    assert_equal calls[1], result[:window]
    assert_match(/#{limit}/, result[:message].to_s)
    refute_includes result[:message].to_s, "a" * 50
  end

  # The same refusal over BMX: the window filed first is reported, the second is refused.
  def test_registration_update_reports_the_windows_filed_before_a_refused_one_over_bmx
    limit = use_bmx
    calls = []
    replace_singleton(RpmsRpc::Agg, :editing) { |**_kw, &block| block.call }
    replace_singleton(RpmsRpc::Agg, :update_patient) do |window:, dfn:, params:, **_kw|
      calls << window
      if calls.size == 1
        { success: true }
      else
        RpmsRpc.client.call_rpc("AGG UPDATE PATIENT", params.values.first)
      end
    end

    result = RpmsRpc::Registration.update("8791", birth_city: "Springfield", address_line1: "a" * 600)

    assert_equal false, result[:success]
    assert_equal :frame_too_long, result[:error]
    assert_equal 1, result[:filed_windows].size
    assert_equal calls[1], result[:window]
    assert_match(/#{limit}/, result[:message].to_s)
    refute_includes result[:message].to_s, "a" * 50
  end

  # Only the AG edit lock and the context bind are skipped here: Agg.update_patient
  # and Agg.encode_parms run for real, so the PARMS string is built by the
  # production code and then refused by the real XWB/BMX frame builder. Nothing
  # was filed before the refused window, so filed_windows is empty.
  [ [ "xwb", :use_xwb, 1000 ], [ "bmx", :use_bmx, 600 ] ].each do |name, user, size|
    define_method("test_registration_update_refuses_the_real_agg_window_over_#{name}") do
      limit = send(user)
      @socket.writes.clear
      RpmsRpc.client.define_singleton_method(:with_context) { |_option, &block| block.call }
      replace_singleton(RpmsRpc::Agg, :editing) { |**_kw, &block| block.call }

      result = RpmsRpc::Registration.update("8791", address_line1: "a" * size)

      assert_equal false, result[:success]
      assert_equal :frame_too_long, result[:error]
      assert_equal "Address", result[:window]
      assert_equal [], result[:filed_windows]
      assert_match(/#{limit}/, result[:message].to_s)
      refute_includes result[:message].to_s, "a" * 50
      assert_empty @socket.writes, "the real encode_parms -> frame builder path sends nothing"
    end
  end

  def test_registration_update_still_raises_for_an_unknown_attribute
    use_xwb
    assert_raises(ArgumentError) { RpmsRpc::Registration.update("8791", nonsense: "x") }
  end

  # -- Referral and DdrFileman: hash results with their own error carrier ----

  def test_referral_add_answers_with_a_failure_hash_over_xwb
    skip_context_binding
    limit = use_xwb
    result = RpmsRpc::Referral.add("8791", "1", XWB_TEXT)
    assert_refused(result, limit, XWB_TEXT)
    assert_equal({ success: false, raw: nil }, result.slice(:success, :raw))
    assert_kind_of String, result[:error]
  end

  # Over BMX the literal params reach the 512-byte request cap. The XWB-only
  # rescue mutant survived without this (panel round 3).
  def test_referral_add_answers_with_a_failure_hash_over_bmx
    skip_context_binding
    limit = use_bmx
    result = RpmsRpc::Referral.add("8791", "1", BMX_TEXT)
    assert_refused(result, limit, BMX_TEXT)
    assert_equal({ success: false, raw: nil }, result.slice(:success, :raw))
    assert_kind_of String, result[:error]
  end

  # XWB only, on purpose: DdrFileman.filer sends a list parameter, which the BMX
  # client refuses with NotImplementedError before any size check, so BMX cannot
  # reach the size refusal (the same reason Problem add/update are XWB only above).
  def test_ddr_filer_answers_with_its_errors_array_over_xwb
    limit = use_xwb
    rows = [ { file: "2", field: ".01", iens: "+1,", value: XWB_TEXT } ]
    result = RpmsRpc::DdrFileman.filer(mode: :add, rows: rows)
    assert_equal false, result[:success]
    assert_equal({}, result[:iens])
    assert_match(/#{limit}/, result[:errors].join(" "))
    refute_includes result[:errors].join(" "), XWB_TEXT
    assert_empty @socket.writes
  end

  # -- The rescue is narrow: only a refused frame becomes a failure hash ------
  # A rescue widened to StandardError (or to the gem's Error / RpcError /
  # ConnectionError) would keep every test above green while swallowing a broker
  # or network failure into { success: false }. Each rescued API family must
  # still let those propagate.
  NON_FRAME_ERRORS = [
    [ "RpcError", -> { RpmsRpc::Client::RpcError.new("broker refused") } ],
    [ "ConnectionError", -> { RpmsRpc::Client::ConnectionError.new("socket lost") } ]
  ].freeze

  RESCUED_FAMILIES = {
    "exam_component" => -> { RpmsRpc::ExamComponent.add("8791", "2090060", "77", finding: "NORMAL", narrative: "ok") },
    "health_factor" => -> { RpmsRpc::HealthFactor.add("8791", "2090060", "55", level: "A", narrative: "ok") },
    "immunization_refusal" => -> { RpmsRpc::ImmunizationRefusal.record("8791", "9", reason_ien: "3", narrative: "ok") },
    "allergy_save" => lambda {
      RpmsRpc::Allergy.save("8791", {
        agent: "PENICILLIN", agent_pointer: "125;PSNDF(50.6,", type: "D", nature: "A",
        originator: "42", originated_at: "3261015.1045", observed_or_historical: "o"
      })
    },
    "allergy_no_known" => -> { RpmsRpc::Allergy.no_known_allergies("8791") },
    "progress_note" => -> { RpmsRpc::ProgressNote.update_text("5001", "ok") },
    "pov" => -> { RpmsRpc::Pov.add("8791", "2090060", "250.00", narrative: "ok") },
    "procedure" => -> { RpmsRpc::Procedure.add("8791", "2090060", "99213", narrative: "ok") },
    "problem_delete" => -> { RpmsRpc::Problem.delete("8791", "77", reason: "ok") },
    "problem_add" => -> { RpmsRpc::Problem.add("8791", { icd_code: "250.00", location_ien: "1", description: "ok" }) },
    "e_signature" => -> { RpmsRpc::ESignature.remove("5001", "12", reason: "ok") },
    "scheduling_add" => lambda {
      RpmsRpc::Scheduling.add_appointment(patient_dfn: "8791", resource: "CLINIC A", start_time: "3261023.0900",
                                          end_time: "3261023.0930", length_minutes: 30, note: "ok")
    },
    "scheduling_cancel" => -> { RpmsRpc::Scheduling.cancel_appointment("55", reason: "3", note: "ok") },
    "referral" => -> { RpmsRpc::Referral.add("8791", "1", "ok") },
    "ddr_filer" => -> { RpmsRpc::DdrFileman.filer(mode: :add, rows: [ { file: "2", field: ".01", iens: "+1,", value: "ok" } ]) },
    "registration_update" => -> { RpmsRpc::Registration.update("8791", address_line1: "ok") },
    "order_save" => lambda {
      RpmsRpc::Order.save("8791", "301", "349", "PSO OERR", { [ 4, 1 ] => "92001" })
    }
  }.freeze

  RESCUED_FAMILIES.each do |family, call|
    NON_FRAME_ERRORS.each do |error_name, build|
      define_method("test_#{family}_lets_a_#{error_name.downcase}_propagate") do
        use_xwb
        skip_context_binding
        replace_singleton(RpmsRpc::Agg, :editing) { |**_kw, &block| block.call }
        client = RpmsRpc.client
        client.define_singleton_method(:with_context) { |_option, &block| block.call }
        error = build.call
        %i[call_rpc call_rpc_lines call_rpc_raw].each do |name|
          client.define_singleton_method(name) { |*_args, **_kw| raise error } if client.respond_to?(name)
        end
        raised = assert_raises(error.class) { instance_exec(&call) }
        assert_same error, raised
      end
    end
  end
end

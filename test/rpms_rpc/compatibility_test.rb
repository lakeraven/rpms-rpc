# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/cia_client"
require "rpms_rpc/xwb_client"
require "rpms_rpc/bmx_client"
require "rpms_rpc/compatibility"

# client.compatibility (rpms-rpc#366): which RPCs this release sends that the server does not
# serve, asked once after sign-on, without running them. Nothing here reaches a broker: each
# client's call_rpc answers from a table, and records what it was asked.
class RpmsRpc::CompatibilityTest < Minitest::Test
  Compatibility = RpmsRpc::Compatibility

  REQUIRED = {
    "build" => "bcer-test",
    "modules" => {
      "RpmsRpc::Patient" => [ "ORWPT ID INFO", "ORWPT SELECT" ],
      "RpmsRpc::Referral" => [ "BMC ADD REFERRAL", "ORWPT SELECT" ],
      "RpmsRpc::Vital" => [ "ORQQVI VITALS" ]
    }
  }.freeze

  # A signed-on client whose call_rpc answers from `replies` (name => lines or a proc of params).
  # A CIA session has the sign-on option bound, as CIANBRPC AUTH leaves it; each call records the
  # option it ran under.
  module Canned
    attr_reader :calls, :contexts

    def setup_canned(replies)
      @replies = replies
      @calls = []
      @contexts = []
      set_authenticated(42)
      @current_context = RpmsRpc::CiaClient::SIGNON_CONTEXT if is_a?(RpmsRpc::CiaClient)
      self
    end

    def call_rpc(name, *params)
      @calls << [ name, *params ]
      @contexts << current_context
      reply = @replies.fetch(name) { raise RpmsRpc::Client::RpcNotAvailableError, "Unknown remote procedure: #{name}" }
      reply.respond_to?(:call) ? reply.call(*params) : reply
    end
  end

  # `registry` is NAME => INACTIVE, or a list of NAMEs (all active).
  def cia(registry)
    RpmsRpc::CiaClient.new(host: "127.0.0.1", port: 9100).extend(Canned).setup_canned("DDR LISTER" => lister_8994(registry))
  end

  # DDR LISTER on #8994 the way LISTC^DDR pages it: the NAMEs that sort after FROM (a string
  # compare, as $O walks the B index), at most MAX of them as IEN^NAME^INACTIVE, then
  # MORE^<last NAME>^ while any remain.
  def lister_8994(registry)
    rows = registry.is_a?(Hash) ? registry : registry.to_h { |name| [ name, "" ] }
    sorted = rows.keys.sort
    lambda do |params|
      after = sorted.select { |name| name > params.fetch("FROM", "") }
      page = after.first(Integer(params.fetch("MAX")))
      more = after.size > page.size ? [ "[Misc]", "MORE^#{page.last}^" ] : []
      more + [ "[Data]" ] + page.map { |name| "#{sorted.index(name) + 1}^#{name}^#{rows[name]}" }
    end
  end

  def xwb(served)
    answer = ->(name, _use) { [ served.include?(name) ? "1" : "0" ] }
    RpmsRpc::XwbClient.new(host: "127.0.0.1", port: 9100).extend(Canned).setup_canned("XWB IS RPC AVAILABLE" => answer)
  end

  def every_required = REQUIRED["modules"].values.flatten.uniq

  # --- the release's list ----------------------------------------------------------------------

  def test_the_shipped_list_names_a_build_and_rpcs_per_api_module
    required = Compatibility.required
    refute_empty required.fetch("build")
    refute_empty required.fetch("modules")
    required["modules"].each do |mod, names|
      assert_match(/\ARpmsRpc::/, mod)
      refute_empty names, "#{mod} lists no RPCs"
      assert_equal names.uniq.sort, names, "#{mod}: names are sorted and unique"
    end
  end

  def test_the_shipped_list_is_in_the_gem
    spec = Gem::Specification.load(File.expand_path("../../rpms-rpc.gemspec", __dir__))
    assert_includes spec.files, "lib/rpms_rpc/required_rpcs.json"
  end

  # --- CIA: one registry read ------------------------------------------------------------------

  def test_cia_reports_nothing_missing_when_the_registry_holds_every_rpc
    client = cia(every_required + [ "XUS SIGNON SETUP" ])
    report = Compatibility.check(client, required: REQUIRED)

    assert_predicate report, :ok?
    assert_empty report.missing
    assert_equal "bcer-test", report.build
    assert_match(/serves every RPC .* \(4 RPCs, derived on bcer-test\)/, report.to_s)
  end

  def test_cia_groups_the_missing_rpcs_by_api_module
    client = cia([ "ORWPT ID INFO", "BMC ADD REFERRAL", "ORQQVI VITALS" ])
    report = Compatibility.check(client, required: REQUIRED)

    refute_predicate report, :ok?
    assert_equal({ "RpmsRpc::Patient" => [ "ORWPT SELECT" ], "RpmsRpc::Referral" => [ "ORWPT SELECT" ] }, report.missing)
    assert_equal [ "ORWPT SELECT" ], report.missing_rpcs
    assert_match(/does not serve 1 of the 4 RPCs/, report.to_s)
    assert_match(/RpmsRpc::Referral: ORWPT SELECT/, report.to_s)
  end

  def test_cia_reads_the_registry_with_ddr_lister_in_the_sign_on_option
    client = cia(every_required)
    Compatibility.check(client, required: REQUIRED)

    assert_equal [ [ "DDR LISTER", { "FILE" => "8994", "FIELDS" => "@;.01;.06I", "FLAGS" => "IP", "MAX" => "1000" } ] ],
                 client.calls
    assert_equal [ "CIAV VUECENTRIC" ], client.contexts
  end

  # INACTIVE "", 0 and 3 run (ACTR^CIANBACT: error 5 is INACTIVE outside "03"); 1 (inactive) and 2
  # (inactive for local use) answer "not available" to a CIA client.
  def test_cia_an_inactive_entry_is_not_served
    registry = { "ORWPT SELECT" => "1", "ORWPT ID INFO" => "2", "ORQQVI VITALS" => "3", "BMC ADD REFERRAL" => "0" }
    report = Compatibility.check(cia(registry), required: REQUIRED)

    assert_equal [ "ORWPT ID INFO", "ORWPT SELECT" ], report.missing_rpcs
  end

  # Each page starts FROM the last NAME alone. "BGOCPTPR CLONE^" (with the caret) sorts after
  # "BGOCPTPR CLONEOTH", which was skipped when it opened a page (found live on the 1012 pin:
  # 5,556 of 5,557 entries).
  def test_cia_pages_resume_from_the_last_name_and_lose_no_entry
    filler = (1..999).map { |i| format("AAA FILLER %04d", i) }
    client = cia(filler + [ "BGOCPTPR CLONE", "BGOCPTPR CLONEOTH" ] + every_required)
    required = { "build" => "t", "modules" => { "RpmsRpc::Probe" => [ "BGOCPTPR CLONEOTH" ] } }

    assert_predicate Compatibility.check(client, required: required), :ok?
    assert_equal [ nil, "BGOCPTPR CLONE" ], client.calls.map { |_name, params| params["FROM"] }
  end

  def test_cia_an_empty_registry_is_a_failed_read_not_everything_missing
    err = assert_raises(RpmsRpc::Client::RpcError) { Compatibility.check(cia([]), required: REQUIRED) }
    assert_match(/DDR LISTER on #8994 answered no RPC names/, err.message)
  end

  def test_cia_a_fileman_error_reply_raises
    client = RpmsRpc::CiaClient.new(host: "127.0.0.1", port: 9100).extend(Canned)
                                .setup_canned("DDR LISTER" => [ "[BEGIN_diERRORS]", "^401^^", "File #8994 does not exist.", "[END_diERRORS]" ])
    err = assert_raises(RpmsRpc::Client::RpcError) { Compatibility.check(client, required: REQUIRED) }
    assert_match(/answered errors: .*File #8994 does not exist/, err.message)
  end

  def test_cia_a_page_that_does_not_advance_raises_rather_than_loop
    stuck = ->(_params) { [ "[Misc]", "MORE^ORWPT SELECT^", "[Data]", "1^ORWPT SELECT^" ] }
    client = RpmsRpc::CiaClient.new(host: "127.0.0.1", port: 9100).extend(Canned).setup_canned("DDR LISTER" => stuck)
    err = assert_raises(RpmsRpc::Client::ParseError) { Compatibility.check(client, required: REQUIRED) }
    assert_match(/did not advance past "ORWPT SELECT"/, err.message)
  end

  # What CIANBRPC GETRPCS sends on every engine (rpms-ops#957): the names run together, because
  # its entry has WORD WRAP ON unset and `W !` ends a row with no bytes on the CIA socket. A row
  # that is not IEN^NAME^INACTIVE fails closed rather than become a name.
  def test_cia_a_row_that_is_not_ien_name_inactive_fails_closed
    run_together = "ADE APPT ADDADE APPT CANCELADE APPT CONFLICTADE APPT DISPLAY"
    client = RpmsRpc::CiaClient.new(host: "127.0.0.1", port: 9100).extend(Canned)
                                .setup_canned("DDR LISTER" => [ "[Data]", "1^ORWPT SELECT^", run_together ])
    err = assert_raises(RpmsRpc::Client::ParseError) { Compatibility.check(client, required: REQUIRED) }
    assert_kind_of RpmsRpc::Error, err
    assert_match(/not IEN\^NAME\^INACTIVE/, err.message)
  end

  def test_cia_a_name_over_30_characters_fails_closed
    long = "ORWPT SELECTORWPT ID INFOORQQVI VITALS"
    assert_raises(RpmsRpc::Client::ParseError) { Compatibility.check(cia(every_required + [ long ]), required: REQUIRED) }
  end

  # The real reply parser, as the YottaDB broker frames a wrap-on DDR LISTER page: sequence echo,
  # ack, then each node followed by CR (OUT^CIANBACT, EOL=$C(13); `W !` adds nothing).
  def test_cia_reads_a_cr_terminated_reply_through_the_real_parser
    raw = "4\x00[Data]\r1^ORWPT SELECT^\r2^ORWPT ID INFO^0\r3^BMC ADD REFERRAL^\r4^ORQQVI VITALS^3\r"
    client = RpmsRpc::CiaClient.new(host: "127.0.0.1", port: 9100)
    client.set_authenticated(42)
    client.instance_variable_set(:@current_context, RpmsRpc::CiaClient::SIGNON_CONTEXT)
    client.define_singleton_method(:call_rpc_raw) { |_name, *_params| raw.b }

    assert_predicate Compatibility.check(client, required: REQUIRED), :ok?
  end

  def test_cia_a_30_character_name_is_a_name
    name = "BMC GET RCIS TEMPLATE DETAIL X"
    assert_equal 30, name.length
    assert_predicate Compatibility.check(cia(every_required + [ name ]), required: REQUIRED), :ok?
  end

  def test_cia_a_broker_that_refuses_the_read_raises_its_typed_error
    client = RpmsRpc::CiaClient.new(host: "127.0.0.1", port: 9100).extend(Canned).setup_canned({})
    assert_raises(RpmsRpc::Client::RpcNotAvailableError) { Compatibility.check(client, required: REQUIRED) }
  end

  # --- XWB: one XWB IS RPC AVAILABLE per RPC ---------------------------------------------------

  def test_xwb_asks_each_rpc_once_for_local_use
    client = xwb(every_required - [ "ORQQVI VITALS" ])
    report = Compatibility.check(client, required: REQUIRED)

    assert_equal({ "RpmsRpc::Vital" => [ "ORQQVI VITALS" ] }, report.missing)
    assert_equal every_required.sort.map { |n| [ "XWB IS RPC AVAILABLE", n, "L" ] }, client.calls
  end

  def test_xwb_an_answer_other_than_1_or_0_raises
    client = RpmsRpc::XwbClient.new(host: "127.0.0.1", port: 9100).extend(Canned).setup_canned("XWB IS RPC AVAILABLE" => [ "" ])
    err = assert_raises(RpmsRpc::Client::RpcError) { Compatibility.check(client, required: REQUIRED) }
    assert_match(/expected 1 or 0, got ""/, err.message)
  end

  # --- the host's choices ----------------------------------------------------------------------

  def test_strict_raises_naming_the_missing_rpcs
    err = assert_raises(Compatibility::MissingRpcsError) do
      Compatibility.check(cia([ "ORWPT SELECT" ]), strict: true, required: REQUIRED)
    end
    assert_kind_of RpmsRpc::Error, err
    assert_equal %w[BMC\ ADD\ REFERRAL ORQQVI\ VITALS ORWPT\ ID\ INFO], err.report.missing_rpcs
    assert_match(/RpmsRpc::Vital: ORQQVI VITALS/, err.message)
  end

  def test_strict_returns_the_report_when_nothing_is_missing
    assert_predicate Compatibility.check(cia(every_required), strict: true, required: REQUIRED), :ok?
  end

  def test_client_compatibility_checks_this_releases_list
    names = Compatibility.required["modules"].values.flatten.uniq
    report = cia(names).compatibility

    assert_predicate report, :ok?
    assert_equal Compatibility.required["build"], report.build
  end

  def test_it_runs_only_after_sign_on
    client = RpmsRpc::CiaClient.new(host: "127.0.0.1", port: 9100)
    err = assert_raises(RpmsRpc::Client::AuthenticationError) { client.compatibility }
    assert_match(/sign on first/, err.message)
  end

  def test_a_broker_without_an_availability_rpc_says_so
    client = RpmsRpc::BmxClient.new(host: "127.0.0.1", port: 9101)
    client.set_authenticated(42)
    err = assert_raises(RpmsRpc::Error) { client.compatibility }
    assert_match(/BmxClient cannot ask its server which RPCs it serves/, err.message)
  end
end

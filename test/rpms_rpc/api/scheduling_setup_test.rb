# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"

# SchedulingSetup reads access types, holidays and a clinic's booking rules with
# DDR LISTER and DDR GETS ENTRY DATA in CIAV VUECENTRIC. The replies are what a
# live rpms-ydb 7c3119b build answered the scheduler persona (2026-10-30); the
# live spec proves the same reads against a container.
class SchedulingSetupTest < Minitest::Test
  # Answers call_rpc from a list of replies in order, and records each call
  # with the context it was bound under.
  class ReplyClient
    attr_reader :calls

    def initialize(*replies)
      @replies = replies
      @calls = []
      @context = "BSDXRPC"
    end

    def with_context(name)
      before = @context
      @context = name
      yield
    ensure
      @context = before
    end

    def call_rpc(rpc, param)
      @calls << { rpc: rpc, param: param, context: @context }
      @replies.shift
    end
  end

  def use(*replies)
    client = ReplyClient.new(*replies)
    RpmsRpc.configure { |c| c.client = client }
    client
  end

  def teardown = RpmsRpc.reset!

  def test_access_types_carry_their_flags_and_are_read_in_ciav_vuecentric
    client = use([ "[Data]", "1^DEMO GENERAL^0^", "2^LIVE SPEC PREVENTS^0^1" ])

    assert_equal [ { id: 1, name: "DEMO GENERAL", inactive: false, prevent_access: false },
                   { id: 2, name: "LIVE SPEC PREVENTS", inactive: false, prevent_access: true } ],
                 RpmsRpc::SchedulingSetup.access_types
    assert_equal [ [ "DDR LISTER", "CIAV VUECENTRIC", "9002018.35" ] ], client.calls.map { |c| [ c[:rpc], c[:context], c[:param]["FILE"] ] }
  end

  def test_holidays_start_the_day_before_and_stop_after_the_last_date
    client = use([ "[Data]", "3261111^3261111^VETERANS DAY", "3261126^3261126^THANKSGIVING DAY", "3261225^3261225^CHRISTMAS DAY" ])

    assert_equal [ { date: Date.new(2026, 11, 11), name: "VETERANS DAY" }, { date: Date.new(2026, 11, 26), name: "THANKSGIVING DAY" } ],
                 RpmsRpc::SchedulingSetup.holidays(start_date: Date.new(2026, 11, 11), end_date: Date.new(2026, 11, 30))
    assert_equal "3261110", client.calls.first[:param]["FROM"]
    assert_equal "B", client.calls.first[:param]["XREF"]
  end

  def test_holidays_read_on_from_the_more_marker
    client = use([ "[Misc]", "MORE^3261126^4", "[Data]", "3261111^3261111^VETERANS DAY" ],
                 [ "[Data]", "3261225^3261225^CHRISTMAS DAY" ])

    assert_equal %w[VETERANS\ DAY CHRISTMAS\ DAY],
                 RpmsRpc::SchedulingSetup.holidays(start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 12, 31)).map { |h| h[:name] }
    assert_equal %w[3261100 3261126], client.calls.map { |c| c[:param]["FROM"] }
  end

  def test_clinic_rules_from_the_hospital_location_fields
    client = use([ "[Data]", "44^6^1914^8", "44^6^1918.5^Y", "44^6^2002^365", "44^6^2500^", "44^6^2505^3270517", "44^6^2506^" ])

    assert_equal({ id: 6, display_begins: 8, schedule_on_holidays: true, max_future_days: 365, prohibit_access: false,
                   inactivate_date: Date.new(2027, 5, 17), reactivate_date: nil },
                 RpmsRpc::SchedulingSetup.clinic_rules(6))
    assert_equal({ "FILE" => "44", "IENS" => "6,", "FIELDS" => "1914;1918.5;2002;2500;2505;2506", "FLAGS" => "I" }, client.calls.first[:param])
    assert_equal "CIAV VUECENTRIC", client.calls.first[:context]
  end

  def test_unset_clinic_fields_read_as_nil_or_false
    use([ "[Data]", "44^8^1914^8", "44^8^1918.5^", "44^8^2002^", "44^8^2500^", "44^8^2505^", "44^8^2506^" ])

    rules = RpmsRpc::SchedulingSetup.clinic_rules(8)
    assert_nil rules[:max_future_days]
    refute rules[:schedule_on_holidays]
  end

  def test_a_refused_or_unanswered_read_raises
    use([ "[ERROR]" ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::SchedulingSetup.clinic_rules(999) }
    use(nil)
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::SchedulingSetup.access_types }
  end
end

# frozen_string_literal: true

require_relative "live_helper"
require_relative "wire_reads"

# The session reads VueCentric makes before and around a chart: who the user
# is and what they may order (BEHOUSCX USERINFO, HASKEYS, NEWPERS), and the
# date strings it turns into FileMan dates (CIAVMRPC STRTODAT, ORWD DT, ORWU
# VALDT, ORWU EXTNAME). Each is sent with the parameters the client sends in
# a recorded session. Read only.
class ChartSessionReadsLiveTest < LiveSpec::Test
  include WireReads

  runs_as :provider

  PROFILE_MD = 206 # the provider's account on every build
  OTHER_USER = 2 # USER,TEST, a user the build seeds without the PROVIDER key

  # USERINFO^BEHOUSCX (BEHOUSCX.m:7-23): DUZ^NAME^ORDER ROLE^CAN SIGN^IS
  # PROVIDER^ORDER ROLE^ORDERING DISABLED^TIMEOUTS^DIVISION. The client
  # sends 0 for the signed-on user.
  def test_userinfo_is_the_signed_on_user
    got = pieces(value("BEHOUSCX USERINFO", "0"))
    assert_equal [ client.duz.to_s, role_row.account ], got[0, 2]
    assert_equal "3", got[2], "PROFILE,MD holds ORES: order role 3, physician"
    assert_equal %w[1 1 3], got.values_at(3, 4, 5), "ORES and a person class: may sign, is a provider, orders as a physician"
    assert_match(/\A\d+;\d+;\d+\z/, got[7], "primary;secondary timeout;countdown")

    other = pieces(value("BEHOUSCX USERINFO", OTHER_USER.to_s))
    assert_equal OTHER_USER.to_s, other[0], "a user's IEN reads that user's row"
    assert_equal entry("200", OTHER_USER, ".01").dig(".01", :external), other[1]
  end

  # HASKEYS^BEHOUSCX (BEHOUSCX.m:46-50): one 1 or 0 per ^-piece of the keys
  # asked, in order; the client asks one at a time, with an @ for a
  # parameter-backed key.
  def test_haskeys_answers_each_key_in_order
    assert_equal "1^1^0^0", value("BEHOUSCX HASKEYS", "PROVIDER^ORES^XUPROGMODE^ORELSE")
    assert_equal "1", value("BEHOUSCX HASKEYS", "PROVIDER")
    assert_equal "0", value("BEHOUSCX HASKEYS", "PROVIDER", OTHER_USER.to_s), "the third parameter asks for another user"
  end

  # NEWPERS^BEHOUSCX (BEHOUSCX.m:52-71): IEN^NAME from the B index, from a
  # name, in a direction, screened by a key, at most CNT.
  def test_newpers_lists_users_by_name_screened_by_key
    got = rows("BEHOUSCX NEWPERS", "PROFILE,M", "1", "PROVIDER", fm_today.to_s, "A", "10").map { |r| pieces(r) }
    refute_empty got
    names = got.map { |r| r[1] }
    assert_equal names.sort, names, "the B index, forward"
    assert names.all? { |n| n > "PROFILE,M" }, "after the name given: #{names.inspect}"
    assert_includes got, [ PROFILE_MD.to_s, "PROFILE,MD" ]
    got.each do |ien, name|
      assert_equal "1", value("BEHOUSCX HASKEYS", "PROVIDER", ien), "#{name} holds PROVIDER, the key screened on"
    end

    two = rows("BEHOUSCX NEWPERS", "PROFILE,M", "1", "", "", "A", "2")
    assert_equal 2, two.size, "CNT caps the list"
    back = rows("BEHOUSCX NEWPERS", "PROFILE,R", "-1", "", "", "A", "3").map { |r| pieces(r)[1] }
    assert_equal back.sort.reverse, back, "direction -1 walks the index backward"
    assert back.all? { |n| n < "PROFILE,R" }
  end

  # STRTODAT^CIAVMRPC (CIAVMRPC.m:122-128): the client's display date to
  # FileMan through ^%DT; a string %DT rejects answers no row.
  def test_strtodat_turns_the_clients_date_into_fileman
    assert_equal "3261006.0052", value("CIAVMRPC STRTODAT", "06-Oct-2026 00:52", "PTSX")
    assert_equal "3261006", value("CIAVMRPC STRTODAT", "06-Oct-2026", "D")
    assert_empty rows("CIAVMRPC STRTODAT", "not a date", "TS").reject(&:empty?)
  end

  # DT^ORWD (ORWD.m:4-6) and VALDT^ORWU (ORWU.m:9-11) run ^%DT on the
  # client's relative dates; a string it rejects is -1.
  def test_relative_dates_are_fileman_dates
    today = fm_today
    assert_equal today.to_s, value("ORWD DT", "T")
    now = value("ORWD DT", "N")
    assert_match(/\A#{today}\.\d{1,6}\z/, now, "N is today with a time")
    seven_ago = RpmsRpc::FilemanDateParser.parse_date(today.to_s) - 7
    assert_equal seven_ago, RpmsRpc::FilemanDateParser.parse_date(value("ORWU VALDT", "T-7"))
    assert_equal today.to_s, value("ORWU VALDT", "T")
    assert_equal "-1", value("ORWU VALDT", "FOO")
  end

  # EXTNAME^ORWU (ORWU.m:163-167): a pointer's .01 through the file's global.
  def test_extname_is_the_pointed_entrys_name
    assert_equal "PROFILE,MD", value("ORWU EXTNAME", PROFILE_MD.to_s, "200")
    patient = entry("2", 4, ".01").dig(".01", :external)
    assert_equal patient, value("ORWU EXTNAME", "4", "2")
  end
end

# The order role USERINFO^BEHOUSCX answers follows the ordering keys a role's
# row holds (BEHOUSCX.m:13): ORES 3, ORELSE 2, OREMAS 1, none 0.
class ChartSessionOrderRoleLiveTest < LiveSpec::Test
  include WireReads

  runs_as :provider, :nurse, :medical_assistant, :front_desk_clerk, :scheduler

  ORDER_ROLES = [ [ "ORES", "3" ], [ "ORELSE", "2" ], [ "OREMAS", "1" ] ].freeze

  def test_order_role_follows_the_rows_ordering_key
    keys = role_row.keys
    expected = ORDER_ROLES.find { |key, _| keys.include?(key) }&.last || "0"
    got = pieces(value("BEHOUSCX USERINFO", "0"))
    assert_equal [ client.duz.to_s, role_row.account, expected ], got[0, 3]
    assert_equal (keys.include?("ORES") ? "1" : "0"), got[3], "may sign orders only with ORES"
    assert_equal (keys.include?("PROVIDER") ? "1" : "0"), value("BEHOUSCX HASKEYS", "PROVIDER")
  end
end

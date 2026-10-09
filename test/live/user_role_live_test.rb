# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/authentication"
require "rpms_rpc/api/ddr_fileman"

# The user's class the gem reports is the server's own: USRCLS,
# piece 3 of ORWU USERINFO, which ORWU.m:19 computes from the user's order
# keys (3 ORES, 2 ORELSE, 1 OREMAS, 0 none) and which CPRS reads the same way.
# Until #236 it was read from XUS AV CODE line 5, the post-sign-on message
# count, so every user came back "user".
#
# Authentication.authenticate itself cannot run over CIA: the broker refuses
# XUS SIGNON SETUP and XUS AV CODE once CIANBRPC AUTH has signed the session
# on. So this spec proves the step authenticate runs after AV CODE,
# Authentication.user_type, in the session and context a CIA sign-on
# binds (CIAV VUECENTRIC), against a direct ORWU USERINFO call.
#
# XUS GET USER INFO is in the XUS SIGNON context; ORWU USERINFO and DDR GETS
# are in CIAV VUECENTRIC. The spec reads only; it files nothing.
class UserRoleLiveTest < LiveSpec::Test
  def test_user_info_line_7_is_the_users_dtime
    duz = client.duz
    info = client.with_context("XUS SIGNON") { RpmsRpc::Authentication.user_info(duz) }
    refute_nil info, "XUS GET USER INFO answered nothing for #{persona}"
    refute info.key?(:user_class_ien), "line 7 is DTIME (XUSRB2.m:35), not a user-class pointer"
    assert_kind_of Integer, info[:dtime]
    assert_operator info[:dtime], :>, 0, "DTIME is a positive number of seconds"

    timed_read = RpmsRpc::DdrFileman.gets_entry(file: "200", iens: "#{duz},", fields: "200.1", flags: "I")
                                    .dig(:fields, "200.1", :internal).to_s
    flunk "#{persona} has no TIMED READ (200.1) on this build, so DTIME is a site default: has the seed changed?" if timed_read.empty?
    assert_equal Integer(timed_read), info[:dtime], "DTIME disagrees with #{persona}'s TIMED READ (200.1)"
  end

  def test_user_type_is_the_servers_usrcls
    duz = client.duz
    usrcls = Integer(Array(client.call_rpc("ORWU USERINFO")).first.to_s.split("^")[2])
    expected = RpmsRpc::Authentication.user_type_for(usrcls)
    refute_nil expected, "ORWU USERINFO answered USRCLS #{usrcls} for #{persona}, which ORWU.m:19 never returns"

    read = RpmsRpc::Authentication.user_type(duz)

    assert_equal expected, read, "ORWU USERINFO says USRCLS #{usrcls} for #{persona}; user_type read #{read.inspect}"
    puts "\n#{persona}: USRCLS #{usrcls} -> user_type #{read}"
  end
end

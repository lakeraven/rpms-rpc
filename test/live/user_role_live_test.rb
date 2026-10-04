# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/security_keys"
require "rpms_rpc/user_roles"
require "rpms_rpc/api/authentication"
require "rpms_rpc/api/ddr_fileman"

# No sign-on reply carries a user class (#236). XUS GET USER INFO's line 7 is
# the user's DTIME (USERINFO^XUSRB2, XUSRB2.m:35), not a user-class pointer;
# the one user class RPMS reports, USRCLS (piece 3 of ORWU USERINFO), is
# computed from the user's security keys (ORWU.m:19). UserRoles.resolve
# derives a role from the same keys, so for each persona it must agree with
# the server's USRCLS.
#
# XUS GET USER INFO is in the XUS SIGNON context; DDR LISTER (the key list)
# and ORWU USERINFO are in CIAV VUECENTRIC, the option sign-on binds. The
# spec reads only; it files nothing.
class UserRoleLiveTest < LiveSpec::Test
  # USRCLS (ORWU.m:19): 3 ORES, 2 ORELSE, 1 OREMAS, 0 none.
  USRCLS_ROLES = { 3 => "provider", 2 => "nurse", 1 => "clerk", 0 => "user" }.freeze

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

  def test_role_from_keys_agrees_with_the_servers_usrcls
    duz = client.duz
    usrcls = Integer(Array(client.call_rpc("ORWU USERINFO")).first.to_s.split("^")[2])
    keys = RpmsRpc::Authentication.user_security_keys(duz)
    role = RpmsRpc::UserRoles.resolve(security_keys: RpmsRpc::SecurityKeys.symbolize(keys))

    assert_equal USRCLS_ROLES.fetch(usrcls), role,
                 "ORWU USERINFO says USRCLS #{usrcls} for #{persona}; the keys (#{keys.size}) resolve to #{role}"
    puts "\n#{persona}: USRCLS #{usrcls} -> #{role}"
  end
end

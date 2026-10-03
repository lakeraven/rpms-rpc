# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/security_keys"
require "rpms_rpc/api/authentication"

# The AG, SD and DG keys SecurityKeys names for registration, scheduling and
# ADT (#296) are keys the pinned build can answer about: for each one, the
# signed-on user asks the server, through ORWU HASKEY
# (HASKEY^ORWU: ''$D(^XUSEC(KEY,DUZ))), whether they hold it, and the server
# answers 0 or 1.
#
# The spec asserts that the call answers, not which way: what a persona holds
# is the build's seed, not the gem's contract. Each persona's answers are
# printed so a run shows them.
#
# ORWU HASKEY is in CIAV VUECENTRIC, the option sign-on binds, for PROV123 and
# for the programmer alike. The spec reads only; it files nothing.
class SecurityKeysLiveTest < LiveSpec::Test
  KEYS = %i[
    registration_menu registration_manager registration_view_only registration_view_ssn benefits_case_reopen
    scheduling_menu scheduling_supervisor scheduling_registration_menu
    adt_menu adt_movement adt_nurse adt_supervisor adt_system adt_incomplete_chart adt_pcc
  ].freeze

  def test_the_server_answers_whether_the_user_holds_each_registration_scheduling_and_adt_key
    answers = KEYS.to_h do |symbol|
      name = RpmsRpc::SecurityKeys.rpms_name(symbol)
      refute_nil name, "SecurityKeys names no key for #{symbol}"
      reply = client.call_rpc("ORWU HASKEY", name)
      assert_includes [ [ "0" ], [ "1" ] ], reply, "ORWU HASKEY #{name} answered #{reply.inspect}, not 0 or 1"
      [ name, reply.first == "1" ]
    end

    puts "\n#{persona} holds: #{answers.select { |_, v| v }.keys.join(', ').then { |s| s.empty? ? '(none of them)' : s }}"
  end

  def test_has_security_key_reports_what_the_server_answers
    duz = client.duz
    refute_nil duz, "sign-on as #{persona} set no DUZ"

    KEYS.each do |symbol|
      name = RpmsRpc::SecurityKeys.rpms_name(symbol)
      expected = client.call_rpc("ORWU HASKEY", name) == [ "1" ]
      assert_equal expected, RpmsRpc::Authentication.has_security_key?(duz, name),
                   "has_security_key?(#{duz}, #{name.inspect}) disagrees with ORWU HASKEY"
    end
  end
end

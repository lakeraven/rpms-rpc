# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/agg"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/referral"
require "rpms_rpc/api/behavioral_health/reference"
require "rpms_rpc/api/practitioner"
require "rpms_rpc/api/coverage"

# Least privilege, proven by refusal (#452). Every other live spec runs as the
# test role whose work it proves; this one runs as every role a broker signs
# on and proves each role's row is minimal: the role is answered under each
# option its row holds and refused under the rest. Each option is tried with
# one read that files nothing.
#
# What a role holds is its row in RpmsRpc::TestRoles (contexts and
# XUPROGMODE), the build's seed (SEEDPERS) as observed on
# bcer-9.0-20261124-60d39b6-ydb. The operator holds XUPROGMODE, so the broker
# lets it run any RPC (CANRUN^CIANBACT, CIANBACT.m:141). When a release
# changes a role's menus this spec fails, and the row moves with the build.
class RoleRefusalLiveTest < LiveSpec::Test
  runs_as :provider, :nurse, :medical_assistant, :front_desk_clerk, :registration_supervisor, :scheduler, :bh_provider, :operator

  # One read per option: registration's own field check, scheduling's clinic
  # list, a patient's referrals, Behavioral Health's clinic list, and a user's
  # divisions and classes (TIU DIV AND CLASS INFO, in OR CPRS GUI CHART only),
  # and iCare's insurance read (BQI PATIENT INSURANCE, in BQIRPC only).
  # A release older than a row's grant fails here, naming the option.
  PROFILE_MD = 206 # the provider's account, a user every build seeds

  READS = {
    "AGGRPC" => -> { RpmsRpc::Agg.validate_field(params: { "AGGPTDOB" => "01/01/1950", "DFN" => "" }) },
    "BSDXRPC" => -> { RpmsRpc::Scheduling.hospital_locations },
    "BMCRPC" => -> { RpmsRpc::Referral.for_patient(2) },
    "AMHGRPC" => -> { RpmsRpc::BehavioralHealth::Reference.clinics },
    "OR CPRS GUI CHART" => -> { RpmsRpc::Practitioner.roles(PROFILE_MD) },
    "BQIRPC" => -> { RpmsRpc::Coverage.for_patient(2) }
  }.freeze

  READS.each do |option, read|
    define_method("test_#{option.downcase.tr(" ", "_")}_answers_its_holders_and_refuses_everyone_else") do
      if role_row.holds?(option)
        refute_nil read.call, "#{role}'s row holds #{option}, and its read gave no answer"
      else
        error = assert_raises(RpmsRpc::Client::RpcRefusedError, "#{role}'s row does not hold #{option}, and its read was answered") do
          read.call
        end
        assert_match(/Access denied for remote procedure/, error.message)
      end
    end
  end

  # The BMX broker checks BMXRPC on the first RPC after the codes
  # (ADDCTXT^BMXMSEC); a CIA registration runs its duplicate lookup there.
  def test_the_bmx_broker_signs_on_its_holders_and_refuses_everyone_else
    port = ENV["BMX_PORT"].to_s.strip
    flunk "BMX_PORT is not set: this spec signs on to the target's BMX broker too" if port.empty?

    bmx = RpmsRpc::BmxClient.new(host: ENV.fetch("BROKER_HOST"), port: Integer(port), timeout: 30)
    bmx.connect
    if role_row.holds?("BMXRPC")
      assert bmx.authenticate(*sign_on_pair)[:success], "#{role}'s row holds BMXRPC"
    else
      assert_raises(RpmsRpc::Client::ContextRefusedError, "#{role}'s row does not hold BMXRPC, and BMX signed it on") do
        bmx.authenticate(*sign_on_pair)
      end
    end
  ensure
    bmx&.disconnect
  end
end

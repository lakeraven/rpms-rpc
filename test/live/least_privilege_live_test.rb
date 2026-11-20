# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/agg"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/referral"
require "rpms_rpc/api/behavioral_health/reference"

# Least privilege, proven by refusal (#452). Every other live spec runs as the
# persona whose role it proves; this one runs as every persona and proves the
# other side: a persona is answered in each option its role holds and refused
# in the rest. Each option is tried with one read that files nothing.
#
# Who holds what is the build's seed (SEEDPERS), as observed on
# bcer-9.0-20261119-f67498c-ydb, where the clinician holds the contexts its
# flows bind (openrpms#1192). The operator holds XUPROGMODE, so the broker
# lets it run any RPC (CANRUN^CIANBACT, CIANBACT.m:141). When a release changes
# a persona's menus this spec fails, and HOLDERS moves with the build.
class LeastPrivilegeLiveTest < LiveSpec::Test
  runs_as "PROV123", "PMD123", "PREG123", "PSCH123", "SYS123"

  HOLDERS = {
    "AGGRPC" => %w[PROV123 PREG123 PSCH123 SYS123],
    "BSDXRPC" => %w[PROV123 PMD123 PREG123 PSCH123 SYS123],
    "BMCRPC" => %w[PROV123 PMD123 SYS123],
    "AMHGRPC" => %w[PROV123 SYS123],
    "BMXRPC" => %w[PROV123 PMD123 PREG123 PSCH123 SYS123]
  }.freeze

  # One read per option: registration's own field check, scheduling's clinic
  # list, a patient's referrals, Behavioral Health's clinic list.
  READS = {
    "AGGRPC" => -> { RpmsRpc::Agg.validate_field(params: { "AGGPTDOB" => "01/01/1950", "DFN" => "" }) },
    "BSDXRPC" => -> { RpmsRpc::Scheduling.hospital_locations },
    "BMCRPC" => -> { RpmsRpc::Referral.for_patient(2) },
    "AMHGRPC" => -> { RpmsRpc::BehavioralHealth::Reference.clinics }
  }.freeze

  READS.each do |option, read|
    define_method("test_#{option.downcase}_answers_its_holders_and_refuses_everyone_else") do
      if HOLDERS.fetch(option).include?(persona)
        refute_nil read.call, "#{persona} holds #{option}, and its read gave no answer"
      else
        error = assert_raises(RpmsRpc::Client::RpcRefusedError, "#{persona} does not hold #{option}, and its read was answered") do
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
    if HOLDERS.fetch("BMXRPC").include?(persona)
      assert bmx.authenticate(ENV.fetch("RPMS_ACCESS"), ENV.fetch("RPMS_VERIFY"))[:success], "#{persona} holds BMXRPC"
    else
      assert_raises(RpmsRpc::Client::ContextRefusedError, "#{persona} does not hold BMXRPC, and BMX signed it on") do
        bmx.authenticate(ENV.fetch("RPMS_ACCESS"), ENV.fetch("RPMS_VERIFY"))
      end
    end
  ensure
    bmx&.disconnect
  end
end

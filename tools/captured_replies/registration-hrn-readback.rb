# frozen_string_literal: true

require "date"
require "rpms_rpc/bmx_client"
require "rpms_rpc/api/authentication"
require "rpms_rpc/api/registration"
require "rpms_rpc/api/ddr_fileman"

# Registration.register's HRN paths, each ending in the #9000001.41 read-back
# (DDR LISTER) that confirms the HRN AG reported filing, recorded as flows as
# PROFILE,REG on a throwaway container. Each register flow files its own
# synthetic patient, with its duplicate lookup on a BMX session signed on as
# the same user (Registration.with_lookup_client); the lookup_* flows record
# that lookup's BMX reply for the same identity, run first, before the patient
# exists. The last two flows read #9000001.41 of the clerk-mode patient (no
# HRN on file) and with an IENS FileMan refuses, for the tests that swap them
# in as the read-back. rpms-rpc#623.
Reg = RpmsRpc::Registration

PATIENTS = {
  "derive" => { name: "SYNTHETIC,DERIVEHRN", dob: Date.new(1902, 3, 1), sex: "F", ssn: "900623001" },
  "temporary" => { name: "SYNTHETIC,TEMPHRN", dob: Date.new(1902, 3, 2), sex: "F", ssn: "900623002", hrn_source: :temporary },
  "given" => { name: "SYNTHETIC,GIVENHRN", dob: Date.new(1902, 3, 3), sex: "F", ssn: "900623003", hrn_source: :given, hrn: "77123" },
  "clerk" => { name: "SYNTHETIC,CLERKHRN", dob: Date.new(1902, 3, 4), sex: "F", ssn: "900623004" }
}.freeze

# The duplicate lookup register makes, on the BMX flow's own session.
def lookup(attrs)
  RpmsRpc::Authentication.authenticate(access_code: "PREG123", verify_code: "PREG123!!")
  params = Reg.send(:agg_add_params, attrs)
  Reg.send(:duplicate_identity, params, allow_duplicate: nil, lookup_client: RpmsRpc.client)
end

def register(attrs, mode: Reg::HRN_MODE_DERIVE)
  bmx = RpmsRpc::BmxClient.new(host: "127.0.0.1", port: Integer(ENV.fetch("BMX_PORT", "9101")), timeout: 30)
  bmx.connect
  bmx.authenticate("PREG123", "PREG123!!")
  Reg.hrn_mode = mode
  result = Reg.with_lookup_client(bmx) { Reg.register(attrs) }
  raise "register did not create the patient: #{result.inspect}" unless result[:dfn]

  $hrn_dfns[attrs[:name]] = result[:dfn] # rubocop:disable Style/GlobalVars
  result
ensure
  Reg.hrn_mode = Reg::HRN_MODE_DERIVE
  bmx&.disconnect
end

def read_hrn_multiple(iens)
  RpmsRpc.client.create_context("CIAV VUECENTRIC")
  RpmsRpc::DdrFileman.lister(file: "9000001.41", iens: iens, fields: "@;.02", flags: "IP")
end

$hrn_dfns = {} # rubocop:disable Style/GlobalVars

CAPTURE = {
  rpc: "AGG ADD NEW PATIENT", entry_point: "ADD^AGGPTADD",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair; DUZ 207)",
  access: "PREG123", verify: "PREG123!!",
  note: "Run on a throwaway container: each register flow files a new synthetic patient, and the DFNs and derived " \
        "HRNs are the ones that container assigned. The BMX sign-on's access/verify pair is withheld.",
  flows: PATIENTS.to_h do |key, attrs|
    [ "lookup_#{key}", { broker: :bmx, withhold: [ "XUS AV CODE" ], about: "the duplicate lookup for #{attrs[:name]}, over BMX",
                         run: -> { lookup(attrs) } } ]
  end.merge(
    "derive" => { about: "register in derive mode", run: -> { register(PATIENTS["derive"]) } },
    "temporary" => { about: "register with a temporary HRN", run: -> { register(PATIENTS["temporary"]) } },
    "given" => { about: "register with the given HRN 77123", run: -> { register(PATIENTS["given"]) } },
    "clerk" => { about: "register in clerk mode, with no HRN", run: -> { register(PATIENTS["clerk"], mode: Reg::HRN_MODE_CLERK) } },
    "no_hrn_on_file" => { about: "#9000001.41 of the clerk-mode patient, which has no HRN",
                          run: -> { read_hrn_multiple(",#{$hrn_dfns.fetch('SYNTHETIC,CLERKHRN')},") } }, # rubocop:disable Style/GlobalVars
    "refused_iens" => { about: "#9000001.41 with an IENS FileMan refuses", run: -> { read_hrn_multiple(",ABC,") } }
  )
}.freeze

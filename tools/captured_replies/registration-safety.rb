# frozen_string_literal: true

require "date"
require "rpms_rpc/bmx_client"
require "rpms_rpc/api/authentication"
require "rpms_rpc/api/registration"
require "rpms_rpc/api/ddr_fileman"

# Registration.register's duplicate-identity preflight, recorded as flows as
# PROFILE,REG on a throwaway container (rpms-rpc#621). Each register flow
# files over CIA, with its duplicate lookup on a BMX session signed on as the
# same user (Registration.with_lookup_client); each lookup_* flow records that
# lookup's BMX reply on its own. In order: UNA's lookup finds nobody and UNA is
# registered; the same lookup then finds UNA; UNA is registered again with
# allow_duplicate: true, after which the lookup finds both. A different name
# on UNA's birth date, and UNA's name on another date, are found too. Last, a
# name given in pieces (with a middle name and suffix) is looked up and
# registered. Synthetic identities only; no SSN (reason N).
Reg = RpmsRpc::Registration
UNA = { name: "SAFETYDEMO,UNA", dob: Date.new(1903, 1, 2), sex: "F", no_ssn_reason: "N" }.freeze
PIECES = { name_last: " safetypieces ", name_first: " una ", name_middle: "MAE", name_suffix: "JR",
           dob: Date.new(1903, 2, 2), sex: "F", no_ssn_reason: "N" }.freeze

# The duplicate lookup register makes, on the BMX flow's own session.
def lookup(attrs)
  RpmsRpc::Authentication.authenticate(access_code: "PREG123", verify_code: "PREG123!!")
  params = Reg.send(:agg_add_params, attrs)
  Reg.send(:duplicate_identity, params, allow_duplicate: nil, lookup_client: RpmsRpc.client)
end

def register(attrs)
  bmx = RpmsRpc::BmxClient.new(host: "127.0.0.1", port: Integer(ENV.fetch("BMX_PORT", "9101")), timeout: 30)
  bmx.connect
  bmx.authenticate("PREG123", "PREG123!!")
  Reg.hrn_mode = Reg::HRN_MODE_DERIVE
  result = Reg.with_lookup_client(bmx) { Reg.register(attrs) }
  raise "register did not create the patient: #{result.inspect}" unless result[:success]

  result
ensure
  bmx&.disconnect
end

def bmx_lookup(about, attrs)
  { broker: :bmx, withhold: [ "XUS AV CODE" ], about: about, run: -> { lookup(attrs) } }
end

CAPTURE = {
  rpc: "AGG LOOKUP PATIENTS", entry_point: "FND^AGGPTLKP",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair; DUZ 207)",
  access: "PREG123", verify: "PREG123!!",
  note: "Run on a fresh throwaway container, flows in order: each register flow files a new synthetic patient, and " \
        "the DFNs and derived HRNs are the ones that container assigned. The BMX sign-on's access/verify pair is withheld.",
  flows: {
    "lookup_first" => bmx_lookup("the duplicate lookup for SAFETYDEMO,UNA (01/02/1903), before she is on file", UNA),
    "register_first" => { about: "register SAFETYDEMO,UNA", run: -> { register(UNA) } },
    "lookup_second" => bmx_lookup("the same lookup, after SAFETYDEMO,UNA is on file", UNA),
    "register_override" => { about: "register SAFETYDEMO,UNA again, with allow_duplicate: true",
                             run: -> { register(UNA.merge(allow_duplicate: true)) } },
    "lookup_both" => bmx_lookup("the same lookup, after the second SAFETYDEMO,UNA is on file", UNA),
    "lookup_other_name" => bmx_lookup("the lookup for SAFETYOTHER,BOB on UNA's birth date",
                                      UNA.merge(name: "SAFETYOTHER,BOB", sex: "M")),
    "lookup_other_dob" => bmx_lookup("the lookup for SAFETYDEMO,UNA born 01/03/1903", UNA.merge(dob: Date.new(1903, 1, 3))),
    "lookup_pieces" => bmx_lookup("the lookup for SAFETYPIECES,UNA MAE JR (02/02/1903), given in pieces", PIECES),
    "register_pieces" => { about: "register SAFETYPIECES,UNA MAE JR, given in pieces", run: -> { register(PIECES) } }
  }
}.freeze

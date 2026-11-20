# frozen_string_literal: true

require "date"
require "rpms_rpc/bmx_client"
require "rpms_rpc/api/authentication"
require "rpms_rpc/api/registration"

# Registration.register's create path through AG, recorded as flows as
# PROFILE,REG on a throwaway container (rpms-rpc#214, #297, #610, #621). Each
# register flow files its own synthetic patient over CIA (the field checks,
# AGG ADD NEW PATIENT, the HRN and its #9000001.41 read-back), with the
# duplicate lookup on a BMX session signed on as the same user. lookup_none is
# that lookup's BMX reply for the first identity, before any is on file: a
# no-match is the bytes of the header alone, whoever is looked up. The refusal
# flows come after the patient whose SSN or HRN they reuse. Each patient has
# a birth date of its own (01/02/1904 on), so no lookup finds another.
Reg = RpmsRpc::Registration
BASE = { sex: "F", tribe: "204", classification: "13", eligibility_status: "I" }.freeze
PATIENTS = {
  "greenfield" => BASE.merge(name: "REGDEMO,UNA", ssn: "900621001", community: "EXAMPLE COMMUNITY"),
  "name_comma" => BASE.merge(name: "REGDEMO,COMMA MAE", ssn: "900621002"),
  "name_pieces" => BASE.merge(name_last: "REGDEMO", name_first: "PIECES", name_middle: "MAE", name_suffix: "JR",
                              ssn: "900621003"),
  "ihs_values" => BASE.merge(name: "REGDEMO,IHS", ssn: "900621004", community_ien: "7421",
                             community_since: Date.new(2020, 5, 1)),
  "extra_fields" => BASE.merge(name: "REGDEMO,EXTRA", ssn: "900621005", extra_fields: [ { field: "1110", value: "4/4" } ]),
  "clerk" => BASE.merge(name: "REGDEMO,CLERK", ssn: "900621006", hrn: "100001"),
  "temporary" => BASE.merge(name: "REGDEMO,TEMP", ssn: "900621007", hrn_source: :temporary),
  "given" => BASE.merge(name: "REGDEMO,GIVEN", ssn: "900621008", hrn_source: :given, hrn: "12345"),
  "given_held" => BASE.merge(name: "REGDEMO,HELD", ssn: "900621009", hrn_source: :given, hrn: "12345"),
  "ssn_held" => BASE.merge(name: "REGDEMO,SSNHELD", ssn: "900621001"),
  "reason_r" => BASE.merge(name: "REGDEMO,REASON", no_ssn_reason: "R"),
  "neither" => BASE.merge(name: "REGDEMO,NEITHER")
}.each_with_index.to_h { |(key, attrs), i| [ key, attrs.merge(dob: Date.new(1904, 1, 2 + i)) ] }.freeze

def lookup(attrs)
  RpmsRpc::Authentication.authenticate(access_code: "PREG123", verify_code: "PREG123!!")
  params = Reg.send(:agg_add_params, attrs)
  Reg.send(:duplicate_identity, params, allow_duplicate: nil, lookup_client: RpmsRpc.client)
end

def register(key, mode: Reg::HRN_MODE_DERIVE)
  bmx = RpmsRpc::BmxClient.new(host: "127.0.0.1", port: Integer(ENV.fetch("BMX_PORT", "9101")), timeout: 30)
  bmx.connect
  bmx.authenticate("PREG123", "PREG123!!")
  Reg.hrn_mode = mode
  result = Reg.with_lookup_client(bmx) { Reg.register(PATIENTS.fetch(key)) }
  warn "#{key}: #{result.inspect}"
  result
ensure
  Reg.hrn_mode = Reg::HRN_MODE_DERIVE
  bmx&.disconnect
end

CAPTURE = {
  rpc: "AGG ADD NEW PATIENT", entry_point: "ADD^AGGPTADD",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair; DUZ 207)",
  access: "PREG123", verify: "PREG123!!",
  note: "Run on a throwaway container, flows in order: each register flow files a new synthetic patient, and the " \
        "DFNs and derived HRNs are the ones that container assigned. Tribe 204, classification 13 and community " \
        "7421 are entries of the build's code files. The BMX sign-on's access/verify pair is withheld.",
  flows: {
    "lookup_none" => { broker: :bmx, withhold: [ "XUS AV CODE" ], about: "the duplicate lookup for REGDEMO,UNA, before she is on file",
                       run: -> { lookup(PATIENTS["greenfield"]) } }
  }.merge(PATIENTS.keys.to_h do |key|
    mode = key == "clerk" ? Reg::HRN_MODE_CLERK : Reg::HRN_MODE_DERIVE
    [ key, { about: "register #{PATIENTS[key][:name] || 'REGDEMO,PIECES MAE JR'} (#{key})", run: -> { register(key, mode: mode) } } ]
  end)
}.freeze
